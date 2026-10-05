import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/account_reset/account_reset_gateway.dart';
import 'package:harmonia_mobile/account_reset/account_reset_host.dart';
import 'package:harmonia_mobile/account_reset/account_reset_presentation.dart';
import 'package:harmonia_mobile/native/native_vault_gateway.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'native_gateway_mapping_test.dart' show PortFixture;
import 'navigation_state_test.dart' show FixtureGateway;

const endpoint = 'https://fixture.example.invalid';
AccountResetOutcome result({
  bool complete = false,
  String id = 'account-fixture',
}) => AccountResetOutcome(
  state: complete ? 'complete' : 'pending',
  accountId: id,
  accountGeneration: complete ? '2' : '1',
  source: complete ? 'commit' : 'status',
  replayed: complete ? false : null,
);
Uint8List input() => Uint8List.fromList([65, 66, 67]);

/// 仅模拟固定原生业务合同，不证明系统槽物理清理或服务器提交。
class ResetFixture implements AccountResetGateway {
  @override
  Set<AccountResetAction> supportedActions = Set.of(AccountResetAction.values);
  final calls = <String>[];
  AccountResetOutcome current = result();
  Completer<void>? email, drain;
  Completer<AccountResetOutcome>? committing;
  bool drainFails = false;
  @override
  Future<void> requestEmailProof(String endpoint, String email) async {
    calls.add('email');
    await this.email?.future;
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
  }

  @override
  Future<AccountResetOutcome> complete() async {
    calls.add('complete');
    return committing?.future ?? result(complete: true);
  }

  @override
  Future<void> invalidate() async {
    calls.add('invalidate');
    await drain?.future;
    if (drainFails) {
      throw const AccountResetFailure(
        AccountResetFailureCode.localCleanupUnconfirmed,
      );
    }
  }
}

class HostFixture extends FixtureGateway
    implements AccountResetGatewayProvider {
  final resets = <ResetFixture>[];
  int projections = 0, logins = 0, inspections = 0;
  ResetFixture get reset => resets.last;
  @override
  AccountResetGateway createAccountResetGateway() {
    final g = ResetFixture();
    resets.add(g);
    return g;
  }

  @override
  void retireAccountResetProjection() {
    projections++;
  }

  @override
  Future<InstanceDescriptor> inspectInstance(String endpoint) async {
    inspections++;
    return super.inspectInstance(endpoint);
  }

  @override
  Future<AccountAuthentication> loginAccount(
    String email,
    String password,
  ) async {
    logins++;
    return super.loginAccount(email, password);
  }
}

Future<VaultController> host(HostFixture g, {bool trusted = false}) async {
  final c = VaultController(gateway: g);
  await c.connectServer(endpoint);
  if (trusted) {
    await c.unlockSavedDevice();
    expect(c.navigate(VaultPage.accountSecurity), isTrue);
  }
  expect(c.navigate(VaultPage.accountReset), isTrue);
  // 显式读取公开投影建立固定范围，不执行任何网络。
  expect(c.accountReset.allows(AccountResetAction.requestEmail), isTrue);
  return c;
}

Future<void> prepared(VaultController c) async {
  await c.requestAccountResetEmail('synthetic@example.invalid');
  final proof = Uint8List.fromList('A2BC3DE4'.codeUnits);
  await c.beginFreshAccountReset(proof);
  expect(proof, everyElement(0));
  final password = input();
  await c.prepareAccountReset(
    password,
    destructiveConfirmation: accountResetConfirmation,
  );
  expect(password, everyElement(0));
}

class ResetCapsPort extends PortFixture {
  Object? resetCap = true, mailCap = true;
  @override
  Future<Map<String, Object?>> capabilities() async => {
    ...await super.capabilities(),
    'nativeAccountReset': resetCap,
    'nativeAccountResetEmailRequest': mailCap,
  };
}

void main() {
  test('仅已验证服务的退出或账号安全入口；默认原生未验收仍关闭', () async {
    final g = FixtureGateway(), c = VaultController(gateway: FixtureGateway());
    expect(c.navigate(VaultPage.accountReset), isFalse);
    expect(c.accountReset.actions, isEmpty);
    await c.connectServer(endpoint);
    expect(c.navigate(VaultPage.accountReset), isTrue);
    expect(c.accountReset.actions, isEmpty);
    await expectLater(
      c.requestAccountResetEmail('synthetic@example.invalid'),
      throwsA(isA<AccountResetFailure>()),
    );
    c.dispose();
    final pending = VaultController(gateway: g);
    await pending.connectServer(endpoint);
    await pending.signIn('synthetic@example.invalid', 'synthetic-password');
    expect(pending.sessionStage, SessionStage.deviceAuthorization);
    expect(pending.navigate(VaultPage.accountReset), isFalse);
    expect(pending.accountReset.actions, isEmpty);
    pending.dispose();
  });

  test('提交同步撤旧视图但不取消自身；未知原流程阻新账号且成功不授信任', () async {
    final g = HostFixture(), c = await host(g, trusted: true);
    await prepared(c);
    g.reset.committing = Completer<AccountResetOutcome>();
    final completion = c.completeAccountReset();
    expect(g.projections, 1);
    expect(c.sessionStage, SessionStage.signedOut);
    expect(c.environments, isEmpty);
    expect(c.checkpoint, 0);
    expect(c.location.page, VaultPage.accountReset);
    expect(g.reset.calls, ['email', 'begin', 'prepare', 'complete']);
    expect(c.accountReset.localCleanupConfirmed, isFalse);
    expect(c.accountReset.allows(AccountResetAction.cancel), isTrue);
    final before = g.inspections;
    await c.connectServer('https://other.example.invalid');
    await c.signIn('other@example.invalid', 'synthetic-password');
    expect(g.inspections, before);
    expect(g.logins, 0);
    g.reset.committing!.completeError(
      const AccountResetFailure(AccountResetFailureCode.nativeRejected),
    );
    await expectLater(completion, throwsA(isA<AccountResetFailure>()));
    expect(c.accountReset.stage, AccountResetStage.unknown);
    expect(c.accountReset.accountId, 'account-fixture');
    expect(c.accountReset.accountGeneration, '1');
    expect(c.accountReset.localCleanupConfirmed, isFalse);
    g.reset.current = result(complete: true);
    await c.queryOriginalAccountReset();
    g.reset.committing = null;
    await c.completeAccountReset();
    expect(c.accountReset.stage, AccountResetStage.complete);
    expect(c.accountReset.localCleanupConfirmed, isTrue);
    expect(c.accountReset.trustedDevice, isFalse);
    expect(c.canEnterVault, isFalse);
    expect(g.reset.calls.where((v) => v == 'invalidate'), isEmpty);
    await c.cancelAccountResetLocally();
    c.dispose();
  });

  test('当前已验账号范围不接受另一账号的邮件结果', () async {
    final g = HostFixture(), c = await host(g, trusted: true);
    await c.requestAccountResetEmail('synthetic@example.invalid');
    g.reset.current = result(id: 'other-account');
    final proof = Uint8List.fromList('A2BC3DE4'.codeUnits);
    await expectLater(
      c.beginFreshAccountReset(proof),
      throwsA(isA<AccountResetFailure>()),
    );
    expect(proof, everyElement(0));
    expect(c.accountReset.allows(AccountResetAction.prepare), isFalse);
    expect(g.reset.calls, ['email', 'begin']);
    await c.cancelAccountResetLocally();
    c.dispose();
  });

  test('inactive认证遮罩不退役；hidden立即取消并拒绝晚到邮件', () async {
    final g = HostFixture(), c = await host(g);
    g.reset.email = Completer<void>();
    final request = c.requestAccountResetEmail('synthetic@example.invalid');
    c.onLifecycleState(AppLifecycleState.inactive);
    expect(g.reset.calls, ['email']);
    c.onLifecycleState(AppLifecycleState.resumed);
    g.reset.email!.complete();
    await request;
    expect(c.accountReset.stage, AccountResetStage.awaitingProof);
    await c.cancelAccountResetLocally();
    expect(c.accountReset.allows(AccountResetAction.requestEmail), isTrue);
    g.reset.email = Completer<void>();
    g.reset.drain = Completer<void>();
    final late = c.requestAccountResetEmail('synthetic@example.invalid');
    c.onLifecycleState(AppLifecycleState.hidden);
    expect(g.reset.calls, ['email', 'invalidate']);
    expect(c.accountReset.actions, isEmpty);
    g.reset.email!.complete();
    await expectLater(late, throwsA(isA<AccountResetFailure>()));
    expect(c.accountReset.stage, AccountResetStage.interrupted);
    c.onLifecycleState(AppLifecycleState.resumed);
    expect(c.accountReset.actions, isEmpty);
    g.reset.drain!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(c.accountReset.allows(AccountResetAction.requestEmail), isTrue);
    c.dispose();
  });

  test('取消busy立即退休；logout等待同一排空，失败不能复开范围', () async {
    final g = HostFixture(), c = await host(g);
    g.reset.email = Completer<void>();
    g.reset.drain = Completer<void>();
    final request = c.requestAccountResetEmail('synthetic@example.invalid');
    final cancel = c.cancelAccountResetLocally();
    expect(c.busy, isFalse);
    expect(c.accountReset.actions, isEmpty);
    final logout = c.logout();
    await Future<void>.delayed(Duration.zero);
    expect(g.logouts, 0);
    expect(g.reset.calls.where((v) => v == 'invalidate').length, 1);
    await c.connectServer('https://other.example.invalid');
    expect(g.inspections, 1);
    g.reset.email!.complete();
    await expectLater(request, throwsA(isA<AccountResetFailure>()));
    g.reset.drain!.complete();
    await cancel;
    await logout;
    expect(g.logouts, 1);
    c.dispose();

    final bad = HostFixture(), locked = await host(bad);
    await locked.requestAccountResetEmail('synthetic@example.invalid');
    bad.reset.drainFails = true;
    await expectLater(
      locked.cancelAccountResetLocally(),
      throwsA(isA<AccountResetFailure>()),
    );
    expect(locked.accountReset.actions, isEmpty);
    expect(locked.switchServer(), isFalse);
    await locked.logout();
    expect(bad.logouts, 0);
    expect(locked.error, isNotNull);
    locked.dispose();
  });

  test('scope修改先退休被动flow；dispose丢晚到结果且不报告清理', () async {
    final g = HostFixture(), c = await host(g);
    final old = g.reset;
    await c.connectServer('https://other.example.invalid');
    expect(old.calls, ['invalidate']);
    expect(c.endpoint, 'https://other.example.invalid');
    expect(c.accountReset.allows(AccountResetAction.requestEmail), isTrue);
    g.reset.email = Completer<void>();
    final request = c.requestAccountResetEmail('synthetic@example.invalid');
    final active = g.reset;
    c.dispose();
    expect(active.calls, ['email', 'invalidate']);
    active.email!.complete();
    await expectLater(request, throwsA(isA<AccountResetFailure>()));
    expect(c.accountReset.localCleanupConfirmed, isFalse);
  });

  test('原生scope门拒地址错配零调用，拒晚到并消耗输入', () async {
    final g = ResetFixture();
    bool current = true;
    final scoped = ScopedAccountResetGateway(g, endpoint, () => current);
    final wrong = input();
    await expectLater(
      scoped.beginFresh('https://other.example.invalid', wrong),
      throwsA(isA<AccountResetFailure>()),
    );
    expect(wrong, everyElement(0));
    expect(g.calls, isEmpty);
    g.committing = Completer<AccountResetOutcome>();
    final late = scoped.complete();
    current = false;
    g.committing!.complete(result(complete: true));
    await expectLater(late, throwsA(isA<AccountResetFailure>()));
    expect(scoped.supportedActions, isEmpty);
    await scoped.invalidate();
    expect(g.calls, ['complete', 'invalidate']);
  });

  test('两compiled布尔与逐项verified求交；旧ordinary operations不授重置', () async {
    Future<NativeVaultGateway> gateway(
      ResetCapsPort port,
      Set<AccountResetAction> verified,
    ) async {
      final g = NativeVaultGateway(
        port: port,
        experimentalOptIn: true,
        verifiedAccountResetActions: verified,
        inspector: (_) async => const InstanceDescriptor(
          initialRegistrationAvailable: false,
          allowRegistration: true,
          emailVerificationRequired: true,
        ),
      );
      await g.initialize('');
      await g.inspectInstance(endpoint);
      g.bindVerifiedServer(endpoint);
      return g;
    }

    final empty = await gateway(ResetCapsPort(), const {});
    expect(empty.createAccountResetGateway().supportedActions, isEmpty);
    final p = ResetCapsPort()..mailCap = false;
    final limited = await gateway(p, Set.of(AccountResetAction.values));
    expect(
      limited.createAccountResetGateway().supportedActions,
      Set.of(AccountResetAction.values)
        ..remove(AccountResetAction.requestEmail),
    );
    final invalid = ResetCapsPort()..resetCap = 'true';
    await expectLater(
      gateway(invalid, Set.of(AccountResetAction.values)),
      throwsA(isA<GatewayFailure>()),
    );
    expect(p.calls, isEmpty); // 只读取能力/实例，未调用任何重置或ordinary业务。
  });
}
