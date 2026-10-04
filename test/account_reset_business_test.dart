import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/account_reset/account_reset_coordinator.dart';
import 'package:harmonia_mobile/account_reset/account_reset_gateway.dart';
import 'package:harmonia_mobile/account_reset/account_reset_presentation.dart';
import 'package:harmonia_mobile/native/native_account_reset_adapter.dart';

const ep = 'https://synthetic.example.invalid';
const account = 'synthetic-account';
AccountResetOutcome outcome({
  bool complete = false,
  String id = account,
  String? generation,
  String source = 'status',
}) => AccountResetOutcome(
  state: complete ? 'complete' : 'pending',
  accountId: id,
  accountGeneration: generation ?? (complete ? '2' : '1'),
  source: source,
  replayed: source == 'commit' ? false : null,
);
String wire({bool complete = false, String source = 'status'}) => jsonEncode({
  'version': 1,
  'trustedDevice': false,
  'outcome': {
    'state': complete ? 'complete' : 'pending',
    'accountId': account,
    'accountGeneration': complete ? '2' : '1',
    'source': source,
    if (source == 'commit') 'replayed': false,
  },
});
Uint8List syntheticInput() => Uint8List.fromList([65, 66, 67]);
void wiped(Uint8List value) => expect(value.every((b) => b == 0), isTrue);
Matcher fixedFailure = isA<AccountResetFailure>();

class GatewayFixture implements AccountResetGateway {
  @override
  Set<AccountResetAction> supportedActions = Set.of(AccountResetAction.values);
  final calls = <String>[];
  AccountResetOutcome current = outcome();
  Completer<AccountResetOutcome>? delayedComplete;
  bool failComplete = false, failPrepare = false, failInvalidate = false;
  @override
  Future<void> requestEmailProof(String endpoint, String email) async {
    calls.add('email');
  }

  @override
  Future<AccountResetOutcome> beginFresh(
    String endpoint,
    Uint8List proof,
  ) async {
    calls.add('begin');
    return current;
  }

  @override
  Future<AccountResetOutcome> beginQueryOnly(
    String endpoint,
    Uint8List proof,
  ) async {
    calls.add('cold');
    return current;
  }

  @override
  Future<AccountResetOutcome> query() async {
    calls.add('query');
    return current;
  }

  @override
  Future<void> prepare(Uint8List password, String confirmation) async {
    calls.add('prepare');
    if (failPrepare) {
      throw const AccountResetFailure(AccountResetFailureCode.nativeRejected);
    }
  }

  @override
  Future<AccountResetOutcome> complete() async {
    calls.add('complete');
    if (delayedComplete != null) {
      return delayedComplete!.future;
    }
    if (failComplete) {
      throw const AccountResetFailure(AccountResetFailureCode.nativeRejected);
    }
    return current = outcome(complete: true, source: 'commit');
  }

  @override
  Future<void> invalidate() async {
    calls.add('invalidate');
    if (failInvalidate) {
      throw StateError('synthetic fixed failure');
    }
  }
}

AccountResetCoordinator coordinator(
  AccountResetGateway g, {
  String id = account,
  String gen = '1',
}) => AccountResetCoordinator(
  g,
  AccountResetScope(ep, accountId: id, accountGeneration: gen),
  changed: () {},
  retireVisibleAccount: () {},
);
Future<void> prepared(AccountResetCoordinator c) async {
  await c.requestAccountResetEmail('synthetic@example.invalid');
  final proof = syntheticInput();
  await c.beginFreshAccountReset(proof);
  wiped(proof);
  final password = syntheticInput();
  await c.prepareAccountReset(
    password,
    destructiveConfirmation: accountResetConfirmation,
  );
  wiped(password);
}

class PortFixture implements NativeAccountResetPort {
  final calls = <String>[];
  String reply = wire();
  bool failComplete = false;
  Completer<String>? delayedQuery;
  @override
  Future<String> begin(String endpoint, Uint8List proof) async {
    calls.add('begin');
    return reply;
  }

  @override
  Future<String> beginQueryOnly(String endpoint, Uint8List proof) async {
    calls.add('cold');
    return reply;
  }

  @override
  Future<String> query() async {
    calls.add('query');
    return delayedQuery?.future ?? Future.value(reply);
  }

  @override
  Future<String> prepare(Uint8List password, String confirmation) async {
    calls.add('prepare');
    return '{"version":1,"prepared":true,"trustedDevice":false}';
  }

  @override
  Future<String> complete() async {
    calls.add('complete');
    if (failComplete) {
      throw StateError('synthetic');
    }
    return wire(complete: true, source: 'commit');
  }

  @override
  Future<void> invalidate() async {
    calls.add('invalidate');
  }
}

NativeAccountResetAdapter adapter(PortFixture port) =>
    NativeAccountResetAdapter(
      port: port,
      compiledActions: Set.of(AccountResetAction.values),
      verifiedActions: Set.of(AccountResetAction.values),
    );

void main() {
  test('默认能力与申请邮件缺口关闭，未发送原生调用', () async {
    final p = PortFixture();
    final a = NativeAccountResetAdapter(
      port: p,
      verifiedActions: Set.of(AccountResetAction.values),
    );
    final c = coordinator(a);
    final proof = syntheticInput();
    expect(c.accountReset.stage, AccountResetStage.unavailable);
    expect(c.accountReset.actions, isEmpty);
    await expectLater(c.queryColdAccountReset(proof), throwsA(fixedFailure));
    wiped(proof);
    final compiled = adapter(p);
    expect(
      compiled.supportedActions.contains(AccountResetAction.requestEmail),
      isFalse,
    );
    await expectLater(
      compiled.requestEmailProof(ep, 'synthetic@example.invalid'),
      throwsA(fixedFailure),
    );
    expect(p.calls, isEmpty);
  });

  test('严格DTO拒额外与重复字段、错误来源和设备信任', () {
    expect(
      decodeAccountResetOutcome(wire(), statusOnly: true).complete,
      isFalse,
    );
    expect(
      decodeAccountResetOutcome(
        wire(complete: true, source: 'commit'),
        statusOnly: false,
      ).complete,
      isTrue,
    );
    for (final raw in [
      wire().replaceFirst('"version":1', '"version":1.0'),
      wire().replaceFirst('"trustedDevice":false', '"trustedDevice":true'),
      wire().replaceFirst('"version":1', '"version":1,"version":1'),
      wire().replaceFirst('"version":1', '"version":1,"\\u0076ersion":1'),
      wire().replaceFirst(
        '"source":"status"',
        '"source":"status","token":"synthetic"',
      ),
      wire().replaceFirst('"state":"pending"', '"state":"ready"'),
      wire().replaceFirst(
        '"accountGeneration":"1"',
        '"accountGeneration":"01"',
      ),
      wire().replaceFirst(
        '"accountGeneration":"1"',
        '"accountGeneration":"18446744073709551615"',
      ),
      wire(complete: true, source: 'commit'),
      '${' ' * 4096}${wire()}',
    ]) {
      expect(
        () => decodeAccountResetOutcome(raw, statusOnly: true),
        throwsA(fixedFailure),
      );
    }
  });

  test('新流程先邮件Query及明确确认，Prepare仅一次且缓冲清零', () async {
    final g = GatewayFixture();
    var visibleRetired = 0;
    final c = AccountResetCoordinator(
      g,
      AccountResetScope(ep, accountId: account, accountGeneration: '1'),
      changed: () {},
      retireVisibleAccount: () {
        visibleRetired++;
      },
    );
    final early = syntheticInput();
    await expectLater(c.beginFreshAccountReset(early), throwsA(fixedFailure));
    wiped(early);
    expect(g.calls, isEmpty);
    await c.requestAccountResetEmail('synthetic@example.invalid');
    final proof = syntheticInput();
    await c.beginFreshAccountReset(proof);
    wiped(proof);
    final wrong = syntheticInput();
    await expectLater(
      c.prepareAccountReset(wrong, destructiveConfirmation: 'OTHER'),
      throwsA(fixedFailure),
    );
    wiped(wrong);
    expect(g.calls, ['email', 'begin']);
    final password = syntheticInput();
    await c.prepareAccountReset(
      password,
      destructiveConfirmation: accountResetConfirmation,
    );
    wiped(password);
    final replacement = syntheticInput();
    await expectLater(
      c.prepareAccountReset(
        replacement,
        destructiveConfirmation: accountResetConfirmation,
      ),
      throwsA(fixedFailure),
    );
    wiped(replacement);
    expect(g.calls, ['email', 'begin', 'prepare']);
    expect(c.accountReset.localCleanupConfirmed, isFalse);
    expect(visibleRetired, 0);
    await c.completeAccountReset();
    expect(visibleRetired, 1);
    expect(c.accountReset.stage, AccountResetStage.complete);
    expect(c.accountReset.localCleanupConfirmed, isTrue);
    expect(c.accountReset.trustedDevice, isFalse);
  });

  test('原RAM提交未知先Query再原无参重试，Query完成不冒称本机清理', () async {
    final g = GatewayFixture();
    final c = coordinator(g);
    await prepared(c);
    g.failComplete = true;
    await expectLater(c.completeAccountReset(), throwsA(fixedFailure));
    expect(c.accountReset.stage, AccountResetStage.unknown);
    expect(c.accountReset.localCleanupConfirmed, isFalse);
    await expectLater(c.completeAccountReset(), throwsA(fixedFailure));
    expect(g.calls.where((x) => x == 'complete').length, 1);
    g.current = outcome(complete: true);
    await c.queryOriginalAccountReset();
    expect(c.accountReset.stage, AccountResetStage.serverComplete);
    expect(c.accountReset.localCleanupConfirmed, isFalse);
    g.failComplete = false;
    await c.completeAccountReset();
    expect(g.calls.where((x) => x == 'prepare').length, 1);
    expect(g.calls.where((x) => x == 'complete').length, 2);
    expect(c.accountReset.localCleanupConfirmed, isTrue);
  });

  test('冷queryOnly及Prepare回应未知不能生成替代原请求', () async {
    final g = GatewayFixture();
    final c = coordinator(g);
    final proof = syntheticInput();
    await c.queryColdAccountReset(proof);
    wiped(proof);
    final pw = syntheticInput();
    await expectLater(
      c.prepareAccountReset(
        pw,
        destructiveConfirmation: accountResetConfirmation,
      ),
      throwsA(fixedFailure),
    );
    wiped(pw);
    await expectLater(c.completeAccountReset(), throwsA(fixedFailure));
    g.current = outcome(complete: true);
    await c.queryOriginalAccountReset();
    expect(c.accountReset.stage, AccountResetStage.serverComplete);
    expect(c.accountReset.localCleanupConfirmed, isFalse);
    expect(g.calls, ['cold', 'query']);
    final g2 = GatewayFixture();
    final c2 = coordinator(g2);
    await c2.requestAccountResetEmail('synthetic@example.invalid');
    await c2.beginFreshAccountReset(syntheticInput());
    g2.failPrepare = true;
    await expectLater(
      c2.prepareAccountReset(
        syntheticInput(),
        destructiveConfirmation: accountResetConfirmation,
      ),
      throwsA(fixedFailure),
    );
    await c2.queryOriginalAccountReset();
    await expectLater(
      c2.prepareAccountReset(
        syntheticInput(),
        destructiveConfirmation: accountResetConfirmation,
      ),
      throwsA(fixedFailure),
    );
    await expectLater(c2.completeAccountReset(), throwsA(fixedFailure));
    expect(g2.calls.where((x) => x == 'prepare').length, 1);
  });

  test('当前账号与代际不匹配拒绝、完成不能倒退成pending', () async {
    final g = GatewayFixture();
    final c = coordinator(g);
    g.current = outcome(id: 'other-account');
    await expectLater(
      c.queryColdAccountReset(syntheticInput()),
      throwsA(fixedFailure),
    );
    expect(c.accountReset.accountId, isEmpty);
    expect(c.accountReset.localCleanupConfirmed, isFalse);
    final g2 = GatewayFixture();
    final c2 = coordinator(g2);
    await c2.queryColdAccountReset(syntheticInput());
    g2.current = outcome(complete: true, generation: '3');
    await expectLater(c2.queryOriginalAccountReset(), throwsA(fixedFailure));
    expect(c2.accountReset.accountGeneration, '1');
    g2.current = outcome(complete: true);
    await c2.queryOriginalAccountReset();
    g2.current = outcome();
    await expectLater(c2.queryOriginalAccountReset(), throwsA(fixedFailure));
    expect(c2.accountReset.accountGeneration, '2');
    expect(g2.calls.where((x) => x == 'complete'), isEmpty);
  });

  test('后台scope退役取消不等busy锁，晚到Complete不能报告完成', () async {
    final g = GatewayFixture();
    final c = coordinator(g);
    await prepared(c);
    g.delayedComplete = Completer();
    final future = c.completeAccountReset();
    await Future<void>.delayed(Duration.zero);
    expect(c.accountReset.busy, isTrue);
    final rejected = expectLater(future, throwsA(fixedFailure));
    await c.onBackground();
    expect(g.calls.last, 'invalidate');
    g.delayedComplete!.complete(outcome(complete: true, source: 'commit'));
    await rejected;
    expect(c.accountReset.stage, AccountResetStage.interrupted);
    expect(c.accountReset.localCleanupConfirmed, isFalse);
    expect(c.accountReset.actions, isEmpty);
    final notificationGateway = GatewayFixture();
    late AccountResetCoordinator notificationCoordinator;
    notificationCoordinator = AccountResetCoordinator(
      notificationGateway,
      AccountResetScope(ep),
      changed: () {
        if (notificationCoordinator.accountReset.busy) {
          unawaited(notificationCoordinator.invalidateScope());
        }
      },
      retireVisibleAccount: () {},
    );
    await expectLater(
      notificationCoordinator.requestAccountResetEmail(
        'synthetic@example.invalid',
      ),
      throwsA(fixedFailure),
    );
    expect(notificationGateway.calls, ['invalidate']);
    final g2 = GatewayFixture()..failInvalidate = true;
    final c2 = coordinator(g2);
    await c2.queryColdAccountReset(syntheticInput());
    await expectLater(c2.invalidateScope(), throwsA(fixedFailure));
    expect(c2.accountReset.actions, isEmpty);
    expect(c2.accountReset.localCleanupConfirmed, isFalse);
  });

  test('native窄port同RAM门和晚到退役，始终不传替代密码', () async {
    final p = PortFixture();
    final a = adapter(p);
    final pwEarly = syntheticInput();
    await expectLater(
      a.prepare(pwEarly, accountResetConfirmation),
      throwsA(fixedFailure),
    );
    wiped(pwEarly);
    await a.beginQueryOnly(ep, syntheticInput());
    await expectLater(
      a.prepare(syntheticInput(), accountResetConfirmation),
      throwsA(fixedFailure),
    );
    await expectLater(a.complete(), throwsA(fixedFailure));
    expect(p.calls, ['cold']);
    p.delayedQuery = Completer();
    final future = a.query();
    final rejected = expectLater(future, throwsA(fixedFailure));
    await a.invalidate();
    p.delayedQuery!.complete(wire());
    await rejected;
    expect(p.calls, ['cold', 'query', 'invalidate']);
    final p2 = PortFixture();
    final a2 = adapter(p2);
    await a2.beginFresh(ep, syntheticInput());
    await a2.prepare(syntheticInput(), accountResetConfirmation);
    p2.failComplete = true;
    await expectLater(a2.complete(), throwsA(fixedFailure));
    await expectLater(a2.complete(), throwsA(fixedFailure));
    await a2.query();
    p2.failComplete = false;
    await a2.complete();
    expect(p2.calls, ['begin', 'prepare', 'complete', 'query', 'complete']);
  });
}
