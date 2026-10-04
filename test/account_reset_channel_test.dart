import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/account_reset/account_reset_gateway.dart';
import 'package:harmonia_mobile/account_reset/account_reset_presentation.dart';
import 'package:harmonia_mobile/native/native_account_reset_adapter.dart';
import 'package:harmonia_mobile/native/native_account_reset_channel.dart';

const endpoint = 'https://synthetic.example.invalid';
const accepted = '{"version":1,"accepted":true,"trustedDevice":false}';
const pending =
    '{"version":1,"trustedDevice":false,"outcome":{"state":"pending","accountId":"synthetic-account","accountGeneration":"7","source":"status"}}';
const completed =
    '{"version":1,"trustedDevice":false,"outcome":{"state":"complete","accountId":"synthetic-account","accountGeneration":"8","source":"commit","replayed":false}}';
const prepared = '{"version":1,"prepared":true,"trustedDevice":false}';

bool wiped(Uint8List bytes) => bytes.every((b) => b == 0);
Matcher failure(AccountResetFailureCode code) =>
    isA<AccountResetFailure>().having((e) => e.code, '固定分类', code);

class MailPortFixture
    implements NativeAccountResetPort, NativeAccountResetMailPort {
  final mail = Completer<String>();
  final cancel = Completer<void>();
  int mails = 0, begins = 0, cancels = 0;
  Uint8List? input;
  @override
  Future<String> requestEmail(String endpoint, Uint8List email) {
    mails++;
    input = email;
    return mail.future;
  }

  @override
  Future<String> begin(String endpoint, Uint8List proof) async {
    begins++;
    return pending;
  }

  @override
  Future<String> beginQueryOnly(String endpoint, Uint8List proof) =>
      begin(endpoint, proof);
  @override
  Future<String> query() async => pending;
  @override
  Future<String> prepare(Uint8List password, String confirmation) async =>
      prepared;
  @override
  Future<String> complete() async => completed;
  @override
  Future<void> invalidate() {
    cancels++;
    return cancel.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.harmoniavault/native/v1');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('七动作仅固定字段，字节独立消费，complete不含替代输入', () async {
    final names = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      names.add(call.method);
      final fields = switch (call.method) {
        'requestAccountResetEmail' => {'endpoint', 'email'},
        'beginAccountReset' ||
        'beginAccountResetQueryOnly' => {'endpoint', 'proof'},
        'prepareAccountReset' => {'password', 'confirmation'},
        _ => <String>{},
      };
      if (fields.isEmpty) {
        expect(call.arguments, isNull);
      } else {
        final args = call.arguments as Map;
        expect(args.keys.toSet(), fields);
        for (final key in ['email', 'proof', 'password']) {
          if (args.containsKey(key)) {
            expect(args[key], isA<Uint8List>());
          }
        }
      }
      return switch (call.method) {
        'requestAccountResetEmail' => accepted,
        'prepareAccountReset' => prepared,
        'completeAccountReset' => completed,
        'cancelAccountReset' => null,
        _ => pending,
      };
    });
    const port = MethodChannelAccountResetPort();
    final email = Uint8List.fromList(utf8.encode('synthetic@example.invalid'));
    expect(await port.requestEmail(endpoint, email), accepted);
    expect(wiped(email), isTrue);
    for (final cold in [false, true]) {
      final proof = Uint8List.fromList(utf8.encode('SYNTHETIC_PROOF_ONLY'));
      if (cold) {
        await port.beginQueryOnly(endpoint, proof);
      } else {
        await port.begin(endpoint, proof);
      }
      expect(wiped(proof), isTrue);
    }
    await port.query();
    final password = Uint8List.fromList(utf8.encode('SYNTHETIC_PASSWORD_ONLY'));
    await port.prepare(password, accountResetConfirmation);
    expect(wiped(password), isTrue);
    await port.complete();
    await port.invalidate();
    expect(names, [
      'requestAccountResetEmail',
      'beginAccountReset',
      'beginAccountResetQueryOnly',
      'queryAccountReset',
      'prepareAccountReset',
      'completeAccountReset',
      'cancelAccountReset',
    ]);
  });

  test('compiled必须精确bool且verified默认空，不把PlatformException秘密投影', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      throw PlatformException(
        code: 'SYNTHETIC_NATIVE_ERROR',
        message: 'SYNTHETIC_PRIVATE_MESSAGE',
        details: {'token': 'SYNTHETIC_PRIVATE_DETAIL'},
      );
    });
    expect(
      compiledAccountResetActions({
        'nativeAccountReset': 'true',
        'nativeAccountResetEmailRequest': 1,
      }),
      isEmpty,
    );
    final declared = compiledAccountResetActions({
      'nativeAccountReset': true,
      'nativeAccountResetEmailRequest': true,
    });
    expect(declared, AccountResetAction.values.toSet());
    final closed = NativeAccountResetAdapter(
      port: const MethodChannelAccountResetPort(),
      compiledActions: declared,
    );
    await expectLater(
      closed.requestEmailProof(endpoint, 'synthetic@example.invalid'),
      throwsA(failure(AccountResetFailureCode.unavailable)),
    );
    expect(calls, 0);
    final active = NativeAccountResetAdapter(
      port: const MethodChannelAccountResetPort(),
      compiledActions: declared,
      verifiedActions: declared,
    );
    await expectLater(
      active.requestEmailProof(endpoint, 'synthetic@example.invalid'),
      throwsA(failure(AccountResetFailureCode.nativeRejected)),
    );
    expect(calls, 1);
  });

  test('mail-only取消不等网络，drain未完或失败永久退休并拒迟到接受', () async {
    final port = MailPortFixture();
    final actions = AccountResetAction.values.toSet();
    final adapter = NativeAccountResetAdapter(
      port: port,
      compiledActions: actions,
      verifiedActions: actions,
    );
    final request = adapter.requestEmailProof(
      endpoint,
      'synthetic@example.invalid',
    );
    final rejected = expectLater(
      request,
      throwsA(failure(AccountResetFailureCode.retired)),
    );
    expect(port.mails, 1);
    final retired = adapter.invalidate();
    final drainFailed = expectLater(
      retired,
      throwsA(failure(AccountResetFailureCode.nativeRejected)),
    );
    expect(port.cancels, 1);
    final proof = Uint8List.fromList([1, 2, 3]);
    await expectLater(
      adapter.beginFresh(endpoint, proof),
      throwsA(failure(AccountResetFailureCode.retired)),
    );
    expect(wiped(proof), isTrue);
    expect(port.begins, 0);
    port.cancel.completeError(StateError('SYNTHETIC_DRAIN_FAILURE'));
    await drainFailed;
    port.mail.complete(accepted);
    await rejected;
    expect(wiped(port.input!), isTrue);
    await expectLater(
      adapter.requestEmailProof(endpoint, 'synthetic@example.invalid'),
      throwsA(failure(AccountResetFailureCode.retired)),
    );
    expect(port.mails, 1);
  });

  test('接受DTO不得夹带账号或信任，也不能以false当成功', () async {
    final actions = AccountResetAction.values.toSet();
    for (final response in [
      '{"version":1,"accepted":true,"trustedDevice":false,"accountId":"synthetic-account"}',
      '{"version":1,"accepted":false,"trustedDevice":false}',
      '{"version":1,"accepted":true,"trustedDevice":true}',
    ]) {
      final port = MailPortFixture()..mail.complete(response);
      final adapter = NativeAccountResetAdapter(
        port: port,
        compiledActions: actions,
        verifiedActions: actions,
      );
      await expectLater(
        adapter.requestEmailProof(endpoint, 'synthetic@example.invalid'),
        throwsA(failure(AccountResetFailureCode.invalidResponse)),
      );
      expect(wiped(port.input!), isTrue);
      port.cancel.complete();
      await adapter.invalidate();
    }
  });
}
