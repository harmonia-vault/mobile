import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/native/native_vault_gateway.dart';
import 'package:harmonia_mobile/native/native_workflow_adapter.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'native_ui_contract_test.dart' show viewFixture, trustedFixture;

/// 只验证Dart实际调用边界，不证明Go/TLS/系统认证真实成功。
class PortFixture implements NativeGatewayPort {
  bool deviceExists = false, verificationRequired = false;
  bool pendingWrite = false, unknownWrite = false;
  String? platformFailure;
  bool registrationExpired = false;
  int profileVersion = 1;
  bool systemStrong = true;
  Set<String>? advertisedOperations;
  String unknownCode = 'PENDING';
  String code = 'SYNTHETIC COMPLETE RECOVERY CODE';
  String initializationState = 'none';
  String? originalId;
  int createCalls = 0, approvalVersion = 0;
  List<int>? consumedCode;
  Map<String, String> pendingFields = {};
  final calls = <(String, Map<String, String>)>[];
  Completer<Map<String, Object?>>? delayedPull, delayedApproval, delayedWrite;
  String approvalState = 'complete', retryApprovalState = 'complete';
  String? pairingId;
  bool cancelApprovalCalled = false;
  Map<String, Object?> view = viewFixture();
  static const operations = {
    'register',
    'verifyEmail',
    'requestVerificationEmail',
    'loginAccount',
    'restoreSession',
    'view',
    'pull',
    'beginInitialization',
    'completeInitialization',
    'queryInitialization',
    'createEnvironment',
    'renameEnvironment',
    'deleteEnvironment',
    'setVariable',
    'deleteVariable',
    'businessPendingInfo',
    'retryBusinessOperation',
    'logout',
    'approvePairing',
    'approvePairingV5',
    'approvalInfoV5',
    'retryApprovalV5',
    'cancelApprovalV5',
  };
  Map<String, Object?> success([Object? data]) => {
    'version': 1,
    'ok': true,
    'experimental': true,
    'data': ?data,
  };
  Map<String, Object?> pending([bool applied = false]) => {
    'id': originalId!,
    'operation': 'put',
    'environmentId': 'env-fixture',
    'state': applied ? 'applied' : 'accepted-not-applied',
    'sequence': 8,
    'applied': applied,
  };
  @override
  Future<Map<String, Object?>> capabilities() async => {
    'version': 1,
    'goCore': true,
    'realVaultReady': false,
    'systemStrongAuthentication': systemStrong,
    'protectedDeviceExists': deviceExists,
  };
  @override
  Future<Map<String, Object?>> profile() async => {
    'version': profileVersion,
    'experimental': true,
    'realVaultReady': false,
    'systemAuthenticationPerOperation': true,
    'operations': (advertisedOperations ?? operations).toList(),
  };
  @override
  Future<Map<String, Object?>> validateEndpoint(String endpoint) async => {
    'version': 1,
    'endpoint': endpoint,
  };
  @override
  Future<Map<String, Object?>> createDevice() async {
    createCalls++;
    deviceExists = true;
    return {'version': 1, 'trusted': false, 'deviceId': 'a' * 64};
  }

  @override
  Future<Map<String, Object?>> execute(
    String endpoint,
    String operation,
    Map<String, String> fields,
  ) async {
    calls.add((operation, Map.of(fields)));
    if (platformFailure != null && operation == 'setVariable') {
      throw PlatformException(code: platformFailure!);
    }
    switch (operation) {
      case 'register':
        return success({
          'accountId': 'account-fixture',
          'accountGeneration': '1',
          'verificationRequired': verificationRequired,
        });
      case 'verifyEmail':
      case 'requestVerificationEmail':
        if (registrationExpired) {
          return {
            'version': 1,
            'experimental': true,
            'ok': false,
            'code': 'REGISTRATION_EXPIRED',
          };
        }
        return success(
          operation == 'requestVerificationEmail' ? {'accepted': true} : null,
        );
      case 'loginAccount':
        return success({'authenticated': true, 'trustedDevice': false});
      case 'restoreSession':
        return success({...trustedFixture(), 'view': view});
      case 'pull':
        return delayedPull?.future ?? success(view);
      case 'beginInitialization':
        initializationState = 'pending';
        return {...success(), 'recoveryCode': code};
      case 'queryInitialization':
        return success({'state': initializationState});
      case 'completeInitialization':
        if (fields['recoveryCode'] != code) {
          return {...success(), 'ok': false, 'code': 'REJECTED'};
        }
        initializationState = 'complete';
        return success(view);
      case 'setVariable':
        if (delayedWrite != null) return delayedWrite!.future;
        if (unknownWrite) {
          pendingWrite = true;
          originalId = fields['id'];
          pendingFields = Map.of(fields);
          return {
            ...success(),
            'ok': false,
            'code': unknownCode,
            'retrySameId': true,
          };
        }
        _apply(fields);
        return success(view);
      case 'businessPendingInfo':
        return success(pendingWrite ? [pending()] : <Object>[]);
      case 'retryBusinessOperation':
        if (fields.keys.toSet().difference({'id'}).isNotEmpty ||
            fields['id'] != originalId) {
          throw StateError('原ID被替换');
        }
        _apply(pendingFields);
        pendingWrite = false;
        return success(pending(true));
      case 'approvalInfoV5':
        return success(
          approvalState == 'none'
              ? {'state': 'none'}
              : {
                  'state': approvalState,
                  'pairingId': pairingId!,
                  if (approvalState == 'complete') 'sequence': 9,
                },
        );
      case 'retryApprovalV5':
        if (fields.keys.toSet().difference({'pairingId'}).isNotEmpty ||
            fields['pairingId'] != pairingId) {
          throw StateError('原审批被替换');
        }
        approvalState = retryApprovalState;
        return success({
          'state': approvalState,
          'pairingId': pairingId!,
          if (approvalState == 'complete') 'sequence': 9,
        });
      case 'cancelApprovalV5':
        if (approvalState != 'prepared' || fields['pairingId'] != pairingId) {
          throw StateError('不得取消已POST审批');
        }
        cancelApprovalCalled = true;
        approvalState = 'none';
        return success();
      case 'logout':
        deviceExists = false;
        return success();
      default:
        return success(view);
    }
  }

  void _apply(Map<String, String> fields) {
    final env = Map<String, Object?>.from(
      (view['environments'] as List).single,
    );
    final variables = Map<String, String>.from(env['variables'] as Map);
    variables[fields['name']!] = fields['value']!;
    env['variables'] = variables;
    view = {
      ...view,
      'checkpoint': 8,
      'environments': [env],
    };
  }

  @override
  Future<Map<String, Object?>> approve(
    String endpoint,
    int version,
    String pairingId,
    Uint8List shortCode,
    List<NativeApprovalSelection> selections,
  ) async {
    approvalVersion = version;
    consumedCode = shortCode;
    this.pairingId = pairingId;
    if (delayedApproval != null) return delayedApproval!.future;
    return success({
      'pairingId': pairingId,
      'state': approvalState,
      if (approvalState == 'complete') 'sequence': 9,
    });
  }
}

class AccountErrorPort extends PortFixture implements NativeAccountPort {
  Map<String, Object?>? failure;

  @override
  Future<Map<String, Object?>> capabilities() async => {
    ...await super.capabilities(),
    'nativePublicAccount': true,
  };

  @override
  Future<Map<String, Object?>> executeAccount(
    String endpoint,
    String operation,
    Map<String, String> fields,
  ) async => failure ?? await super.execute(endpoint, operation, fields);
}

Future<NativeVaultGateway> connected(
  PortFixture port, {
  bool testEvidence = true,
  Set<String>? verifiedEvidence,
}) async {
  final g = NativeVaultGateway(
    experimentalOptIn: true,
    port: port,
    verifiedNativeOperations:
        verifiedEvidence ?? (testEvidence ? PortFixture.operations : null),
    inspector: (_) async => const InstanceDescriptor(
      initialRegistrationAvailable: true,
      allowRegistration: false,
      emailVerificationRequired: false,
    ),
  );
  await g.initialize('');
  await g.inspectInstance('https://fixture.example.invalid');
  g.bindVerifiedServer('https://fixture.example.invalid');
  return g;
}

void main() {
  for (final entry in {
    'ACCOUNT_EXISTS': '此邮箱已注册或正在注册，请登录或完成邮箱验证。',
    'ACCOUNT_FORMAT_UNSUPPORTED': '账号数据无法读取，请联系服务器管理员。',
    'REGISTRATION_DISABLED': '服务器已关闭注册，请联系管理员。',
    'EMAIL_INVALID': '邮箱格式不正确，请检查后重试。',
    'EMAIL_DELIVERY_FAILED': '验证码邮件发送失败，请联系服务器管理员。',
    'EMAIL_UNAVAILABLE': '服务器邮件服务不可用，请联系管理员。',
    'NETWORK_ERROR': '连接未完成，请检查网络和服务器地址后重试。',
    'SERVER_RESPONSE_INVALID': '服务器响应无法识别，请确认客户端和服务器均已更新。',
    'SERVER_UNAVAILABLE': '服务器暂时不可用，请稍后重试或联系管理员。',
    'REQUEST_RATE_LIMITED': '请求过于频繁，请稍后重试。',
    'ACCOUNT_REQUEST_FAILED': '账号操作未完成，请重试或联系服务器管理员。',
  }.entries) {
    test('注册失败显示具体原因并停留当前步骤 ${entry.key}', () async {
      final port = AccountErrorPort()
        ..failure = {
          'version': 1,
          'experimental': true,
          'ok': false,
          'code': entry.key,
          'message': 'synthetic-secret',
          'data': trustedFixture(),
        };
      final gateway = await connected(port);
      final controller = VaultController(gateway: gateway);
      await controller.initialize();
      await controller.connectServer('https://fixture.example.invalid');
      await controller.registerAccount(
        'fixture@example.invalid',
        'synthetic-only',
      );
      expect(controller.error, entry.value);
      expect(controller.location.page, VaultPage.registration);
      expect(controller.registration, isNull);
      expect(controller.canEnterVault, isFalse);
      expect(controller.busy, isFalse);
      expect(port.deviceExists, isFalse);

      port.failure = null;
      port.verificationRequired = true;
      await controller.registerAccount(
        'fixture@example.invalid',
        'synthetic-only',
      );
      expect(controller.error, isNull);
      expect(controller.location.page, VaultPage.emailProof);
      expect(controller.canEnterVault, isFalse);
      controller.dispose();
    });
  }
  test('登录拒绝显示账号提示且不进入设备授权', () async {
    final port = AccountErrorPort()
      ..failure = {
        'version': 1,
        'experimental': true,
        'ok': false,
        'code': 'LOGIN_FAILED',
      };
    final gateway = await connected(port);
    final controller = VaultController(gateway: gateway);
    await controller.initialize();
    await controller.connectServer('https://fixture.example.invalid');
    controller.navigate(VaultPage.login);
    await controller.signIn('fixture@example.invalid', 'synthetic-only');
    expect(controller.error, '登录失败，请检查邮箱、密码，并确认已完成邮箱验证。');
    expect(controller.location.page, VaultPage.login);
    expect(controller.sessionStage, SessionStage.signedOut);
    expect(controller.canEnterVault, isFalse);
    expect(controller.busy, isFalse);
    controller.dispose();
  });
  test('public同源Android证据仅开启新四意图，整体ready仍false且login不trust', () async {
    final f = PortFixture(), g = await connected(f, testEvidence: false);
    for (final operation in [
      'loginAccount',
      'restoreSession',
      'businessPendingInfo',
      'retryBusinessOperation',
    ]) {
      expect(g.capabilities.contains(operation), true);
    }
    expect(g.realVaultReady, false);
    final auth = await g.loginAccount(
      'fixture@example.invalid',
      'synthetic-only',
    );
    expect(auth.authenticated, true);
    expect(auth.trustedDevice, false);
    await expectLater(g.pull(), throwsA(isA<GatewayFailure>()));
  });
  test('runtime advertisement单独不够，没有独立证据则四项全部关闭', () async {
    final f = PortFixture(), g = await connected(f, verifiedEvidence: const {});
    for (final operation in [
      'loginAccount',
      'restoreSession',
      'businessPendingInfo',
      'retryBusinessOperation',
    ]) {
      expect(g.capabilities.contains(operation), false);
    }
    await expectLater(
      g.loginAccount('fixture@example.invalid', 'synthetic-only'),
      throwsA(isA<GatewayFailure>()),
    );
    expect(f.calls, isEmpty);
    expect(f.createCalls, 0);
  });
  test('独立证据不替代当前runtime支持，未知operation不会变成权限', () async {
    final f = PortFixture()
      ..advertisedOperations = {'futureSensitiveOperation'};
    final g = await connected(f, testEvidence: false);
    expect(g.capabilities, isEmpty);
    await expectLater(
      g.loginAccount('fixture@example.invalid', 'synthetic-only'),
      throwsA(isA<GatewayFailure>()),
    );
    expect(f.calls, isEmpty);
    expect(f.createCalls, 0);
  });
  test('未知profile版本拒绝，即使自报所有已验操作也不能调用', () async {
    final f = PortFixture()..profileVersion = 2;
    final g = NativeVaultGateway(experimentalOptIn: true, port: f);
    await expectLater(g.initialize(''), throwsA(isA<GatewayFailure>()));
    expect(g.capabilities, isEmpty);
    expect(f.calls, isEmpty);
  });
  test('系统强认证不可用时证据与runtime同时具备也不降级开放', () async {
    final f = PortFixture()..systemStrong = false;
    final g = await connected(f, testEvidence: false);
    expect(g.capabilities, isEmpty);
    await expectLater(
      g.loginAccount('fixture@example.invalid', 'synthetic-only'),
      throwsA(isA<GatewayFailure>()),
    );
    expect(f.calls, isEmpty);
    expect(f.createCalls, 0);
  });
  test('绑定必须先实际inspect，已有本机钥拒跨endpoint替换', () async {
    final f = PortFixture(), g = await connected(f);
    expect(
      () => g.bindVerifiedServer('https://other.example.invalid'),
      throwsA(isA<GatewayFailure>()),
    );
    final own = await connected(f);
    await own.registerAccount('fixture@example.invalid', 'synthetic-only');
    await own.inspectInstance('https://other.example.invalid');
    expect(
      () => own.bindVerifiedServer('https://other.example.invalid'),
      throwsA(isA<GatewayFailure>()),
    );
  });
  test('登录只身份，注册不跳vault，已有钥不覆盖create', () async {
    final f = PortFixture(), g = await connected(f);
    final auth = await g.loginAccount(
      'fixture@example.invalid',
      'synthetic-only',
    );
    expect(auth.authenticated, true);
    expect(auth.trustedDevice, false);
    await expectLater(g.pull(), throwsA(isA<GatewayFailure>()));
    final own = await connected(f);
    await own.registerAccount('fixture@example.invalid', 'synthetic-only');
    await own.loginAccount('fixture@example.invalid', 'synthetic-only');
    expect(f.createCalls, 1);
  });
  test('首机完整新码由native返回，错误重输不可信，正确后明确cert5', () async {
    final f = PortFixture(), g = await connected(f);
    final c = VaultController(gateway: g);
    await c.initialize();
    await c.connectServer('https://fixture.example.invalid');
    await c.registerAccount('fixture@example.invalid', 'synthetic-only');
    expect(c.location.page, VaultPage.initialization);
    expect(c.canEnterVault, false);
    await c.beginInitialization(
      'fixture@example.invalid',
      'synthetic-only',
      '合成首个环境',
    );
    expect(c.initializationCode, f.code);
    expect(c.canEnterVault, false);
    await c.completeInitialization('wrong-complete-synthetic-code');
    expect(c.canEnterVault, false);
    expect(c.initializationCode, f.code);
    await c.completeInitialization(f.code);
    expect(c.canEnterVault, true);
    expect(c.initializationCode, isNull);
    await c.approveDevice(
      ApprovalDraft(
        pairingId: 'fixture-pair-id',
        code: '01234567',
        roles: {'env-fixture': AccessRole.readWrite},
        lifetime: const Duration(hours: 1),
      ),
    );
    expect(f.approvalVersion, 5);
    expect(f.consumedCode, everyElement(0));
    c.dispose();
  });
  test('emailproof独立页面，成功仍untrusted，旧proof/password不作trusted', () async {
    final f = PortFixture()..verificationRequired = true;
    final g = await connected(f), c = VaultController(gateway: g);
    await c.initialize();
    await c.connectServer('https://fixture.example.invalid');
    await c.registerAccount('fixture@example.invalid', 'synthetic-only');
    expect(c.location.page, VaultPage.emailProof);
    expect(c.canEnterVault, false);
    await c.verifyRegistrationEmail('a2bc-3de4');
    expect(c.sessionStage, SessionStage.deviceAuthorization);
    expect(c.location.page, VaultPage.initialization);
    expect(c.canEnterVault, false);
    expect(f.calls.last.$1, 'verifyEmail');
    expect(f.calls.last.$2.keys.toSet(), {
      'accountId',
      'accountGeneration',
      'code',
    });
    expect(f.calls.last.$2['code'], 'A2BC3DE4');
    expect(g.capabilities.contains('verifyEmail'), true);
    c.dispose();
  });
  for (final resend in [false, true]) {
    test('注册过期可重新开始且不会进入设备授权 resend=$resend', () async {
      var now = DateTime.utc(2026, 10, 5);
      final f = PortFixture()..verificationRequired = true;
      final g = await connected(f),
          c = VaultController(gateway: g, now: () => now);
      await c.initialize();
      await c.connectServer('https://fixture.example.invalid');
      await c.registerAccount('fixture@example.invalid', 'synthetic-only');
      f.registrationExpired = true;
      now = now.add(const Duration(minutes: 15));
      if (resend) {
        await c.resendRegistrationEmail();
      } else {
        await c.verifyRegistrationEmail('A2BC3DE4');
      }
      expect(c.registrationExpired, true);
      expect(c.error, '本次注册已过期，请重新注册。');
      expect(c.sessionStage, SessionStage.signedOut);
      expect(c.canEnterVault, false);
      expect(c.navigate(VaultPage.registration), true);
      f.registrationExpired = false;
      await c.registerAccount('fixture@example.invalid', 'synthetic-only');
      expect(c.registrationExpired, false);
      expect(c.emailResendSeconds, 60);
      c.dispose();
    });
  }
  test('未知write关闭旧view，不生新ID，query/retry仅原id，final下发才可见', () async {
    final f = PortFixture()..unknownWrite = true;
    final g = await connected(f), c = VaultController(gateway: g);
    await c.initialize();
    await c.connectServer('https://fixture.example.invalid');
    await c.unlockSavedDevice();
    await c.setVariable('env-fixture', 'DEMO_VALUE', 'synthetic-new');
    expect(c.vaultSuspended, true);
    expect(c.environments, isEmpty);
    await c.setVariable('env-fixture', 'DEMO_VALUE', 'different-new-intent');
    expect(f.calls.where((entry) => entry.$1 == 'setVariable').length, 1);
    await c.queryBusinessPending();
    expect(c.businessPending.single.id, f.originalId);
    await c.retryBusinessPending(f.originalId!);
    expect(c.canEnterVault, true);
    expect(c.environments.single.variables.single.value, 'synthetic-new');
    final retry = f.calls
        .where((entry) => entry.$1 == 'retryBusinessOperation')
        .single;
    expect(retry.$2, {'id': f.originalId});
    expect(g.realVaultReady, false);
    c.dispose();
  });
  test('过大完整JSON在native前拒，确定OS取消不留假pending或覆盖旧内容', () async {
    final f = PortFixture(), g = await connected(f);
    await g.restoreSession();
    await expectLater(
      g.submit(
        PreviewMutation(
          PreviewOperation.setVariable,
          environmentId: 'env-fixture',
          name: 'DEMO_VALUE',
          value: '汉' * 12000,
        ),
      ),
      throwsA(isA<GatewayFailure>()),
    );
    final own = await connected(f);
    await own.restoreSession();
    f.platformFailure = 'AUTH_CANCELLED';
    await expectLater(
      own.submit(
        const PreviewMutation(
          PreviewOperation.setVariable,
          environmentId: 'env-fixture',
          name: 'DEMO_VALUE',
          value: 'synthetic-new',
        ),
      ),
      throwsA(isA<GatewayFailure>()),
    );
    f.platformFailure = null;
    await own.submit(
      const PreviewMutation(
        PreviewOperation.setVariable,
        environmentId: 'env-fixture',
        name: 'DEMO_VALUE',
        value: 'synthetic-new',
      ),
    );
    expect(f.calls.where((entry) => entry.$1 == 'setVariable').length, 2);
  });
  test('冷恢复可信 DAG 会话后可继续授权设备', () async {
    final f = PortFixture(), g = await connected(f);
    await g.restoreSession();
    expect(g.capabilities.contains('approveDevice'), true);
    await g.approve(
      ApprovalDraft(
        pairingId: 'fixture-pair-id',
        code: '01234567',
        roles: {'env-fixture': AccessRole.readWrite},
        lifetime: null,
      ),
    );
    expect(f.approvalVersion, 5);
  });
  test('approved仅批准，原PairID查询/续办不新短码不新签包，complete后恢复视图', () async {
    final f = PortFixture()..approvalState = 'approved';
    final g = await connected(f), c = VaultController(gateway: g);
    await c.initialize();
    await c.connectServer('https://fixture.example.invalid');
    await c.registerAccount('fixture@example.invalid', 'synthetic-only');
    await c.beginInitialization(
      'fixture@example.invalid',
      'synthetic-only',
      '合成环境',
    );
    await c.completeInitialization(f.code);
    await c.approveDevice(
      ApprovalDraft(
        pairingId: 'fixture-pair-id',
        code: '01234567',
        roles: {'env-fixture': AccessRole.readWrite},
        lifetime: null,
      ),
    );
    expect(c.approvalProgress.state, 'approved');
    expect(c.canEnterVault, false);
    expect(c.environments, isEmpty);
    expect(f.consumedCode, everyElement(0));
    await c.queryApproval();
    expect(c.canEnterVault, false);
    await c.cancelApproval();
    expect(f.cancelApprovalCalled, false);
    await c.retryApproval();
    expect(c.approvalProgress.state, 'complete');
    expect(c.canEnterVault, true);
    expect(f.calls.where((e) => e.$1 == 'retryApprovalV5').single.$2, {
      'pairingId': 'fixture-pair-id',
    });
    expect(f.approvalVersion, 5);
    c.dispose();
  });
  for (final lateState in ['approved', 'complete', 'AUTH_CANCELLED']) {
    test('旧scope晚到审批$lateState不得复活或清空新scope审批', () async {
      final f = PortFixture(), g = await connected(f);
      await g.beginInitialization(
        'fixture@example.invalid',
        'synthetic-only',
        '合成环境',
      );
      await g.completeInitialization(f.code);
      final delayed = Completer<Map<String, Object?>>();
      f.delayedApproval = delayed;
      final old = g.approve(
        ApprovalDraft(
          pairingId: 'old-pair-id',
          code: '01234567',
          roles: {'env-fixture': AccessRole.readWrite},
          lifetime: null,
        ),
      );
      final rejected = expectLater(old, throwsA(isA<GatewayFailure>()));
      await Future<void>.delayed(Duration.zero);
      await g.logout();
      await g.inspectInstance('https://other.example.invalid');
      g.bindVerifiedServer('https://other.example.invalid');
      f.delayedApproval = null;
      await g.beginInitialization(
        'fixture@example.invalid',
        'synthetic-only',
        '新合成环境',
      );
      await g.completeInitialization(f.code);
      f.approvalState = 'approved';
      await g.approve(
        ApprovalDraft(
          pairingId: 'new-pair-id',
          code: '12345678',
          roles: {'env-fixture': AccessRole.readWrite},
          lifetime: null,
        ),
      );
      if (lateState == 'AUTH_CANCELLED') {
        delayed.completeError(PlatformException(code: 'AUTH_CANCELLED'));
      } else {
        delayed.complete(
          f.success({
            'pairingId': 'old-pair-id',
            'state': lateState,
            if (lateState == 'complete') 'sequence': 9,
          }),
        );
      }
      await rejected;
      expect(g.approvalProgress.pairingId, 'new-pair-id');
      expect(g.approvalProgress.state, 'approved');
      expect(f.consumedCode, everyElement(0));
    });
  }
  test('旧write晚到OS取消不能解除新scope未知原事务的写入门槛', () async {
    final f = PortFixture(), g = await connected(f);
    await g.restoreSession();
    final delayed = Completer<Map<String, Object?>>();
    f.delayedWrite = delayed;
    const mutation = PreviewMutation(
      PreviewOperation.setVariable,
      environmentId: 'env-fixture',
      name: 'DEMO_VALUE',
      value: 'synthetic-only',
    );
    final old = g.submit(mutation);
    final rejected = expectLater(old, throwsA(isA<GatewayFailure>()));
    await Future<void>.delayed(Duration.zero);
    await g.logout();
    await g.inspectInstance('https://other.example.invalid');
    g.bindVerifiedServer('https://other.example.invalid');
    await g.restoreSession();
    f.delayedWrite = null;
    f.unknownWrite = true;
    await expectLater(g.submit(mutation), throwsA(isA<GatewayFailure>()));
    delayed.completeError(PlatformException(code: 'AUTH_CANCELLED'));
    await rejected;
    await expectLater(g.submit(mutation), throwsA(isA<GatewayFailure>()));
    expect(f.calls.where((e) => e.$1 == 'setVariable').length, 2);
  });
  test('REJECTED且原journal retrySameId不能当未提交，关闭旧view仅续原ID', () async {
    final f = PortFixture()
      ..unknownWrite = true
      ..unknownCode = 'REJECTED';
    final g = await connected(f), c = VaultController(gateway: g);
    await c.initialize();
    await c.connectServer('https://fixture.example.invalid');
    await c.unlockSavedDevice();
    await c.setVariable('env-fixture', 'DEMO_VALUE', 'synthetic-new');
    expect(c.vaultSuspended, true);
    expect(c.environments, isEmpty);
    await c.queryBusinessPending();
    await c.retryBusinessPending(f.originalId!);
    expect(c.canEnterVault, true);
    expect(c.environments.single.variables.single.value, 'synthetic-new');
    expect(f.calls.where((e) => e.$1 == 'setVariable').length, 1);
    c.dispose();
  });
}
