import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/native/native_dag_recovery_adapter.dart';
import 'package:harmonia_mobile/native/native_vault_gateway.dart';
import 'package:harmonia_mobile/recovery/recovery_gateway.dart';
import 'package:harmonia_mobile/recovery/recovery_presentation.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'native_gateway_mapping_test.dart' show PortFixture;

// 合成协议/业务测试；不证明真实系统认证、Go HTTP 或用户点击链。
const endpoint = 'https://fixture.example.invalid';
final fixedNow = DateTime.utc(2030, 1, 1);
Map<String, Object?> header() => {
  'version': 1,
  'profile': dagRecoveryProfile,
  'trustedDevice': false,
};
Map<String, Object?> owner({bool rotated = false}) => {
  'recoveryGeneration': rotated ? '2' : '1',
  'sequence': rotated ? '11' : '10',
  'environments': 1,
  'rotationRequired': !rotated,
  'trustedDevice': false,
  'expiresAt':
      (fixedNow.add(const Duration(minutes: 15)).millisecondsSinceEpoch ~/ 1000)
          .toString(),
};
Map<String, Object?> preparation({bool exists = false}) => {
  ...header(),
  'state': exists ? 'preparation-pending' : 'none',
  'operationId': exists ? 'transition-original' : '',
  'phase': exists ? 'challenged' : '',
  'needsOriginalOwner': exists,
};
Map<String, Object?> pending({bool exists = false, bool applied = false}) => {
  ...header(),
  'state': !exists
      ? 'none'
      : applied
      ? 'accepted-original'
      : 'pending',
  'operationId': exists ? 'transition-original' : '',
  'kind': exists ? 'transition-v2' : '',
  'contentHash': exists ? 'b' * 64 : '',
  'acceptance': applied ? 'accepted' : 'unknown',
  'acceptedSequence': applied ? '11' : '0',
  'originalApplied': applied,
};
Map<String, Object?> enrolled({
  bool exists = false,
  bool applied = false,
  bool interrupted = false,
}) => {
  ...header(),
  'state': interrupted
      ? 'interrupted-original'
      : !exists
      ? 'none'
      : applied
      ? 'accepted-not-device-applied'
      : 'pending-original',
  'operationId': exists || interrupted ? 'enrollment-original' : '',
  'phase': interrupted ? 'intent' : '',
  'contentHash': exists ? 'c' * 64 : '',
  'acceptance': applied ? 'accepted' : 'unknown',
  'acceptedSequence': applied ? '12' : '0',
  'originalConfirmed': applied,
  'needsOriginalOwner': interrupted,
};
Map<String, Object?> trusted({
  String generation = '1',
  String checkpoint = '13',
}) => {
  ...header(),
  'trustedDevice': true,
  'operationId': 'enrollment-original',
  'contentHash': 'c' * 64,
  'acceptedSequence': '12',
  'binding': {
    'accountId': 'account-fixture',
    'accountGeneration': generation,
    'deviceId': 'a' * 64,
    'checkpoint': checkpoint,
  },
  'view': {
    'deviceId': 'a' * 64,
    'checkpoint': checkpoint,
    'experimental': true,
    'environments': [
      {
        'id': 'env-fixture',
        'name': '合成环境',
        'role': 'RO',
        'variables': {'DEMO_SYNTHETIC': 'synthetic-only'},
      },
    ],
  },
};
Map<String, Object?> envelope(
  String op,
  Object? data, {
  String? soft,
  bool generated = false,
}) => {
  ...header(),
  'operation': op,
  'ok': soft == null,
  'trustedDevice':
      soft == null &&
      {
        'applyDAGRecoveredDevice',
        'restoreDAGRecoveredDevice',
        'pullDAGRecoveredDevice',
      }.contains(op),
  if (generated && soft == null) 'recoveryCode': data else 'data': data,
  if (soft != null)
    'error': {'code': soft, 'ownerRetained': true, 'retryOriginal': true},
};

class DAGPortFixture extends PortFixture
    implements NativeDAGRecoveryPort, NativeDAGProfilePort {
  Set<String> dagOperations = dagRecoveryFields.keys
      .where((op) => op != 'cancelDAGRecoveryOwner')
      .toSet();
  bool nativeCancel = true;
  @override
  Future<Map<String, Object?>> capabilities() async => {
    ...await super.capabilities(),
    'nativeDAGOwnerCancellation': nativeCancel,
  };
  @override
  Future<Map<String, Object?>> dagWorkflowProfile() async => {
    'version': 1,
    'profile': dagRecoveryProfile,
    'experimental': true,
    'realVaultReady': false,
    'systemAuthenticationPerOperation': true,
    'dispatch': 'executeDAGRecovery',
    'operations': dagOperations.toList(),
  };
  final dagCalls = <(String, Map<String, String>)>[];
  Map<String, Object?> p = pending(), e = enrolled(), prep = preparation();
  bool rotated = false,
      softReentry = false,
      softSubmit = false,
      softSealEnrollment = false;
  Completer<Map<String, Object?>>? delayed;
  String? delayOperation;
  String generation = '1', checkpoint = '13';
  Uint8List? lastBytes;
  @override
  Future<Map<String, Object?>> executeDAGRecovery(
    String ep,
    String op,
    Map<String, String> fields,
    Uint8List code,
  ) async {
    dagCalls.add((op, Map.of(fields)));
    lastBytes = code;
    if (op == delayOperation) return delayed!.future;
    switch (op) {
      case 'cancelDAGRecoveryOwner':
        return {
          'version': 1,
          'operation': op,
          'localOwnerClosed': true,
          'journalPreserved': true,
          'trustedDevice': false,
        };
      case 'openDAGRecoveryOwner':
        return envelope(op, owner());
      case 'dagRecoveryResolutionDiscovery':
        final state = e['state'] != 'none' || prep['state'] != 'none'
            ? 'unsupported'
            : p['state'] == 'none'
            ? 'none'
            : 'supported-original';
        return envelope(op, {
          'version': 1,
          'profile': 'recovery-operation-closure-v1',
          'state': state,
          'operationId': state == 'supported-original' ? p['operationId'] : '',
          'targetHash': state == 'supported-original' ? 'e' * 64 : '',
          'trustedDevice': false,
        });
      case 'dagRecoveryResolutionInfo':
        return envelope(op, {
          'version': 1,
          'profile': 'recovery-operation-closure-v1',
          'operationId': p['operationId'],
          'targetHash': 'e' * 64,
          'observation': 'unknown',
          'localState': 'pending',
          'confirmation': 'none',
          'sequence': '0',
          'rotationRequired': true,
          'trustedDevice': false,
        });
      case 'dagRecoveredDeviceInfo':
        return envelope(op, e);
      case 'dagRecoveryPreparationInfo':
        return envelope(op, prep);
      case 'dagRecoveryPendingInfo':
        return envelope(op, p);
      case 'beginDAGRecoveryTransition':
        prep = preparation(exists: true);
        return envelope(
          op,
          'SYNTHETIC GENERATED COMPLETE CODE',
          generated: true,
        );
      case 'sealDAGRecoveryTransition':
        if (softReentry) {
          return envelope(op, owner(), soft: 'NEW_CODE_REENTRY_REQUIRED');
        }
        prep = preparation();
        p = pending(exists: true);
        return envelope(op, p);
      case 'retryDAGRecoveryTransition':
        if (softSubmit) {
          return envelope(op, owner(), soft: 'ORIGINAL_RETRY_REQUIRED');
        }
        rotated = true;
        p = pending(exists: true, applied: true);
        return envelope(op, owner(rotated: true));
      case 'dagRecoveredEnrollmentChoices':
        return envelope(op, {
          ...header(),
          'sequence': '11',
          'recoveryHeadHash': 'd' * 64,
          'environments': [
            {'environmentId': 'env-fixture', 'keyVersion': '1'},
          ],
        });
      case 'sealDAGRecoveredDevice':
        if (softSealEnrollment) {
          e = enrolled(interrupted: true);
          return envelope(op, e, soft: 'ORIGINAL_RETRY_REQUIRED');
        }
        e = enrolled(exists: true);
        return envelope(op, e);
      case 'retryDAGRecoveredDevice':
        e = enrolled(exists: true, applied: true);
        return envelope(op, e);
      case 'applyDAGRecoveredDevice':
      case 'restoreDAGRecoveredDevice':
      case 'pullDAGRecoveredDevice':
        return envelope(
          op,
          trusted(generation: generation, checkpoint: checkpoint),
        );
      default:
        throw const GatewayFailure('fixture 操作未配置');
    }
  }
}

Future<(VaultController, NativeVaultGateway, DAGPortFixture)> setup({
  DAGPortFixture? fixture,
  Set<String>? evidence,
}) async {
  final f = fixture ?? DAGPortFixture();
  final g = NativeVaultGateway(
    experimentalOptIn: true,
    port: f,
    verifiedDAGOperations: evidence ?? dagRecoveryFields.keys.toSet(),
    now: () => fixedNow,
    inspector: (_) async => const InstanceDescriptor(
      initialRegistrationAvailable: false,
      allowRegistration: false,
      emailVerificationRequired: false,
    ),
  );
  final c = VaultController(gateway: g, now: () => fixedNow);
  await c.initialize();
  await c.connectServer(endpoint);
  return (c, g, f);
}

Uint8List code() =>
    Uint8List.fromList(utf8.encode('SYNTHETIC COMPLETE RECOVERY CODE'));
Future<void> opened(VaultController c) async {
  await c.inspectRecovery();
  await c.openRecovery(
    email: 'synthetic@example.invalid',
    password: 'synthetic-only',
    currentCode: code(),
  );
}

Future<void> transition(VaultController c) async {
  await opened(c);
  await c.prepareRecoveryCode();
  await c.sealRecoveryTransition(code());
  await c.submitRecoveryTransition();
}

RecoverySelection selection({
  RecoveryRole role = RecoveryRole.readOnly,
  RecoveryExpiry? expiry,
  String version = '1',
}) => RecoverySelection(
  environmentId: 'env-fixture',
  keyVersion: version,
  role: role,
  expiry: expiry ?? const RecoveryExpiry.untilRevoked(),
);
Future<void> enrollment(VaultController c) async {
  await transition(c);
  await c.loadRecoveryChoices();
  await c.sealRecoveryEnrollment([selection()]);
  await c.submitRecoveryEnrollment();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('strict DAG DTO拒绝旧profile、额外secret、B3a伪trusted和binding不一致', () {
    final value = envelope(
      'dagRecoveredDeviceInfo',
      enrolled(exists: true, applied: true),
    );
    expect(
      decodeDAGRecovery('dagRecoveredDeviceInfo', value).payload,
      isA<RecoveryEnrollment>(),
    );
    for (final bad in [
      {...value, 'profile': 'recovery-dag-v1'},
      {...value, 'secret': 'synthetic'},
      {...value, 'trustedDevice': true},
      {
        ...value,
        'data': {
          ...enrolled(exists: true, applied: true),
          'acceptedSequence': 12,
        },
      },
      {
        ...value,
        'data': {
          ...enrolled(exists: true, applied: true),
          'originalConfirmed': false,
          'acceptedSequence': '0',
        },
      },
    ]) {
      expect(
        () => decodeDAGRecovery('dagRecoveredDeviceInfo', bad),
        throwsA(isA<GatewayFailure>()),
      );
    }
    final t = trusted();
    (t['binding'] as Map)['checkpoint'] = '14';
    expect(
      () => decodeDAGRecovery(
        'applyDAGRecoveredDevice',
        envelope('applyDAGRecoveredDevice', t),
      ),
      throwsA(isA<GatewayFailure>()),
    );
  });
  test('soft tuple必须活owner true+固定操作错误；query枚举使用真实native合同', () {
    final soft = envelope(
      'sealDAGRecoveryTransition',
      owner(),
      soft: 'NEW_CODE_REENTRY_REQUIRED',
    );
    expect(
      decodeDAGRecovery('sealDAGRecoveryTransition', soft).softError,
      'NEW_CODE_REENTRY_REQUIRED',
    );
    (soft['error'] as Map)['ownerRetained'] = false;
    expect(
      () => decodeDAGRecovery('sealDAGRecoveryTransition', soft),
      throwsA(isA<GatewayFailure>()),
    );
    final q = envelope('queryDAGRecoveryOriginal', {
      ...header(),
      'pending': pending(exists: true, applied: true),
      'observation': 'accepted',
      'confirmation': 'original-verified-and-saved',
      'rotationRequired': true,
    });
    expect(
      decodeDAGRecovery('queryDAGRecoveryOriginal', q).payload,
      isA<RecoveryQuery>(),
    );
  });
  test('MethodChannel仅两个精确参数，码不进入JSON，success/failure都清零', () async {
    const channel = MethodChannel('org.harmoniavault/native/v1');
    var calls = 0;
    var reject = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          expect(call.method, 'executeDAGRecovery');
          final args = call.arguments as Map;
          expect(args.keys.toSet(), {'command', 'completeCode'});
          final command = jsonDecode(args['command'] as String) as Map;
          expect(command.keys.toSet(), {
            'version',
            'endpoint',
            'operation',
            'email',
            'password',
          });
          expect(
            (args['command'] as String).contains('COMPLETE RECOVERY CODE'),
            false,
          );
          expect(args['completeCode'], isA<Uint8List>());
          if (reject) throw PlatformException(code: 'AUTH_CANCELLED');
          return jsonEncode(envelope('openDAGRecoveryOwner', owner()));
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    for (final fail in [false, true]) {
      reject = fail;
      final input = code();
      final call = const NativeDAGRecoveryAdapter().executeDAGRecovery(
        endpoint,
        'openDAGRecoveryOwner',
        {'email': 'synthetic@example.invalid', 'password': 'synthetic-only'},
        input,
      );
      if (fail) {
        await expectLater(call, throwsA(isA<PlatformException>()));
      } else {
        await call;
      }
      expect(input.every((b) => b == 0), true);
    }
    final invalid = code();
    await expectLater(
      const NativeDAGRecoveryAdapter().executeDAGRecovery(
        endpoint,
        'oldRecovery',
        {},
        invalid,
      ),
      throwsA(isA<GatewayFailure>()),
    );
    expect(invalid.every((b) => b == 0), true);
    expect(calls, 2);
  });
  test('能力需要runtime与独立证据；默认空不因preview/广告开放', () async {
    final (c, g, f) = await setup(evidence: {});
    addTearDown(c.dispose);
    expect(g.recoveryCapabilities, isEmpty);
    expect(c.recovery.actions, isEmpty);
    final input = code();
    await c.openRecovery(
      email: 'synthetic@example.invalid',
      password: 'synthetic-only',
      currentCode: input,
    );
    expect(f.dagCalls, isEmpty);
    expect(input.every((b) => b == 0), true);
    final f2 = DAGPortFixture()
      ..dagOperations = {}
      ..nativeCancel = false;
    final (c2, g2, _) = await setup(fixture: f2);
    addTearDown(c2.dispose);
    expect(g2.recoveryCapabilities, isEmpty);
  });
  test('完整向导显式提交与选择：B2/B3a不能trust，只有B3b随后DAG读取', () async {
    final (c, g, f) = await setup();
    addTearDown(c.dispose);
    await opened(c);
    expect(c.sessionStage, SessionStage.restrictedRecovery);
    expect(c.recovery.trustedDevice, false);
    await c.prepareRecoveryCode();
    expect(c.recoveryCodeForDisplay, isNull);
    c.setRecoveryCodeVisible(true);
    expect(c.recoveryCodeForDisplay, contains('SYNTHETIC'));
    await c.sealRecoveryTransition(code());
    expect(c.recoveryCodeForDisplay, isNull);
    expect(f.rotated, false);
    expect(c.recovery.operationId, 'transition-original');
    await c.submitRecoveryTransition();
    expect(c.recovery.trustedDevice, false);
    await c.loadRecoveryChoices();
    expect(c.recovery.choices.single.keyVersion, '1');
    await c.sealRecoveryEnrollment([
      selection(
        role: RecoveryRole.readWrite,
        expiry: RecoveryExpiry.until(fixedNow.add(const Duration(hours: 1))),
      ),
    ]);
    final fields = f.dagCalls.last.$2;
    final rows = jsonDecode(fields['selections']!) as List;
    expect(rows.single, {
      'environmentId': 'env-fixture',
      'keyVersion': '1',
      'role': 'rw',
      'expiresAt':
          (fixedNow.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
                  1000)
              .toString(),
    });
    expect(c.recovery.trustedDevice, false);
    await c.submitRecoveryEnrollment();
    expect(c.recovery.trustedDevice, false);
    expect(c.canEnterVault, false);
    await c.verifyRecoveredDevice();
    expect(c.canEnterVault, true);
    expect(c.recovery.trustedDevice, true);
    expect(c.environments.single.variables.single.value, 'synthetic-only');
    expect(g.capabilities, {
      'queryApproval',
      'retryApproval',
      'cancelApproval',
    });
    await c.reload();
    expect(f.dagCalls.last.$1, 'pullDAGRecoveredDevice');
    expect(
      f.calls.where((x) => {'pull', 'restoreSession'}.contains(x.$1)),
      isEmpty,
    );
  });
  test('错误新码保持同owner原意图；提交未知只续原ID不生成新码', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await opened(c);
    await c.prepareRecoveryCode();
    f.softReentry = true;
    final input = code();
    await c.sealRecoveryTransition(input);
    expect(input.every((b) => b == 0), true);
    expect(c.recovery.ownerAvailable, true);
    expect(c.recovery.newCodeAvailable, true);
    expect(c.recovery.allows(RecoveryAction.prepareCode), false);
    f.softReentry = false;
    await c.sealRecoveryTransition(code());
    f.softSubmit = true;
    await c.submitRecoveryTransition();
    expect(c.recovery.operationId, 'transition-original');
    expect(c.recovery.ownerAvailable, true);
    expect(c.recovery.allows(RecoveryAction.submitTransition), true);
    expect(c.recovery.allows(RecoveryAction.prepareCode), false);
    expect(c.recovery.trustedDevice, false);
  });
  test('空选择/过期/重复/错误版本不调用原生登记', () async {
    for (final rows in <List<RecoverySelection>>[
      [],
      [selection(expiry: RecoveryExpiry.until(fixedNow))],
      [selection(), selection()],
      [selection(version: '2')],
    ]) {
      final (c, _, f) = await setup();
      await transition(c);
      await c.loadRecoveryChoices();
      final count = f.dagCalls.length;
      await c.sealRecoveryEnrollment(rows);
      expect(f.dagCalls.length, count);
      expect(c.recovery.trustedDevice, false);
      expect(c.recovery.ownerAvailable, true);
      c.dispose();
    }
  });
  test('challenge soft之后保留原选择，不允许改角色重试', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await transition(c);
    await c.loadRecoveryChoices();
    f.softSealEnrollment = true;
    await c.sealRecoveryEnrollment([selection()]);
    expect(c.recovery.operationId, 'enrollment-original');
    expect(c.recovery.allows(RecoveryAction.submitEnrollment), false);
    final count = f.dagCalls.length;
    await c.sealRecoveryEnrollment([selection(role: RecoveryRole.admin)]);
    expect(f.dagCalls.length, count);
  });
  test('本机取消不等待在途请求；晚到B3b不能trusted且原ID保留', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await enrollment(c);
    f.delayOperation = 'applyDAGRecoveredDevice';
    f.delayed = Completer();
    final verifying = c.verifyRecoveredDevice();
    await Future<void>.delayed(Duration.zero);
    expect(c.busy, true);
    await c.cancelRecoveryLocally();
    expect(c.busy, false);
    expect(c.recovery.operationId, 'enrollment-original');
    f.delayed!.complete(envelope('applyDAGRecoveredDevice', trusted()));
    await verifying;
    expect(c.canEnterVault, false);
    expect(c.recovery.trustedDevice, false);
    expect(c.recoveryCodeForDisplay, isNull);
  });
  test('Logout与晚到B3b隔离：清理成功后旧响应不能重建会话', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await enrollment(c);
    f.delayOperation = 'applyDAGRecoveredDevice';
    f.delayed = Completer();
    final verifying = c.verifyRecoveredDevice();
    await Future<void>.delayed(Duration.zero);
    await c.logout();
    f.delayed!.complete(envelope('applyDAGRecoveredDevice', trusted()));
    await verifying;
    expect(c.sessionStage, SessionStage.signedOut);
    expect(c.canEnterVault, false);
    expect(c.recovery.operationId, isNull);
  });
  test('真实后台清新码并退役晚到生成结果，不借resumed复活owner', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await opened(c);
    f.delayOperation = 'beginDAGRecoveryTransition';
    f.delayed = Completer();
    final generating = c.prepareRecoveryCode();
    await Future<void>.delayed(Duration.zero);
    c.setForeground(false);
    f.delayed!.complete(
      envelope(
        'beginDAGRecoveryTransition',
        'SYNTHETIC LATE CODE',
        generated: true,
      ),
    );
    await generating;
    c.setForeground(true);
    expect(c.recovery.newCodeAvailable, false);
    expect(c.recovery.ownerAvailable, false);
    expect(c.recoveryCodeForDisplay, isNull);
  });
  test('已恢复DAG后generation变化/检查点倒退拒绝并关闭明文', () async {
    for (final change in ['generation', 'rollback']) {
      final (c, _, f) = await setup();
      await enrollment(c);
      await c.verifyRecoveredDevice();
      if (change == 'generation') {
        f.generation = '2';
      } else {
        f.checkpoint = '12';
      }
      await c.reload();
      expect(c.canEnterVault, false);
      expect(c.environments, isEmpty);
      c.dispose();
    }
  });
  test('CAS回应未知保原登记，新的正式Restore可恢复但不走旧authority', () async {
    final (c, g, f) = await setup();
    addTearDown(c.dispose);
    await enrollment(c);
    f.delayOperation = 'applyDAGRecoveredDevice';
    f.delayed = Completer();
    final apply = c.verifyRecoveredDevice();
    await Future<void>.delayed(Duration.zero);
    f.delayed!.completeError(
      PlatformException(code: 'GO_OR_KEYSTORE_REJECTED'),
    );
    await apply;
    expect(c.canEnterVault, false);
    expect(c.recovery.operationId, 'enrollment-original');
    expect(c.recovery.allows(RecoveryAction.restoreDevice), true);
    await c.restoreRecoveredDevice();
    expect(c.canEnterVault, true);
    expect(f.dagCalls.last.$1, 'restoreDAGRecoveredDevice');
    expect(c.phase, ConnectionPhase.offline);
    expect(c.recovery.status, contains('离线'));
    await c.pullRecoveredDevice();
    expect(c.phase, ConnectionPhase.online);
    final previous = f.calls.length;
    await expectLater(
      g.loginAccount('synthetic@example.invalid', 'synthetic-only'),
      throwsA(isA<GatewayFailure>()),
    );
    expect(f.calls.length, previous);
  });
  test('服务器关闭能力缺失：绝不借本机取消代替且始终消费码', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await opened(c);
    final before = f.dagCalls.length;
    final input = code();
    await c.closeRecoveryOriginal(input, destructiveConfirmed: true);
    expect(f.dagCalls.length, before);
    expect(input.every((b) => b == 0), true);
    expect(c.recovery.allows(RecoveryAction.closeOriginal), false);
    expect(c.recovery.ownerAvailable, true);
  });
  test('恢复面板直接Pull的硬失败也清trusted与旧明文，不仅reload路径', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await enrollment(c);
    await c.verifyRecoveredDevice();
    f.generation = '2';
    await c.pullRecoveredDevice();
    expect(c.recovery.trustedDevice, false);
    expect(c.canEnterVault, false);
    expect(c.environments, isEmpty);
    expect(c.recovery.allows(RecoveryAction.restoreDevice), true);
  });
  test('新安装无protectedDevice不强行读受保护元数据，首次open才创建设备', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    expect(c.recovery.allows(RecoveryAction.open), true);
    await c.inspectRecovery();
    expect(f.dagCalls, isEmpty);
    expect(f.createCalls, 0);
    await c.openRecovery(
      email: 'synthetic@example.invalid',
      password: 'synthetic-only',
      currentCode: code(),
    );
    expect(f.createCalls, 1);
    expect(f.dagCalls.single.$1, 'openDAGRecoveryOwner');
  });
  test('cold inspect只读原intent，不能自动owner或普通login替换', () async {
    final f = DAGPortFixture()
      ..e = enrolled(interrupted: true)
      ..deviceExists = true;
    final (c, _, _) = await setup(fixture: f);
    addTearDown(c.dispose);
    await c.inspectRecovery();
    expect(c.recovery.operationId, 'enrollment-original');
    expect(c.recovery.needsOriginalOwner, true);
    expect(c.recovery.ownerAvailable, false);
    expect(c.recovery.allows(RecoveryAction.open), false);
    expect(c.recovery.allows(RecoveryAction.submitEnrollment), false);
    expect(f.dagCalls.map((x) => x.$1), [
      'dagRecoveryResolutionDiscovery',
      'dagRecoveredDeviceInfo',
    ]);
  });
}
