import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/management/management_gateway.dart';
import 'package:harmonia_mobile/management/management_presentation.dart';
import 'package:harmonia_mobile/native/native_management_contract.dart';
import 'package:harmonia_mobile/native/native_vault_gateway.dart';
import 'package:harmonia_mobile/native/native_workflow_adapter.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'native_gateway_mapping_test.dart' show PortFixture;
import 'recovery_business_test.dart' show DAGPortFixture;

// 只有合成Dart/native DTO，不证明系统认证、管理HTTP或CLI已经运行。
const env = 'env-fixture', target = 'reader-fixture';
final clock = DateTime.utc(2030, 1, 1);
Map<String, Object?> info({
  String id = '',
  String state = 'none',
  String kind = 'grant',
  String subject = target,
}) => {
  'state': state,
  'attempted': state != 'none' && state != 'prepared',
  if (state != 'none') ...{
    'id': id,
    'kind': kind,
    'environmentId': env,
    'subjectDeviceId': subject,
    if (kind == 'revoke')
      'expiresAt':
          clock.add(const Duration(minutes: 2)).millisecondsSinceEpoch ~/ 1000,
    if (state == 'accepted-not-applied') 'sequence': 9,
  },
};
Map<String, Object?> result(
  String id, {
  bool applied = true,
  bool accepted = true,
  bool unknown = false,
  bool canceled = false,
}) => {
  'id': id,
  'accepted': accepted,
  'applied': applied,
  'acceptanceUnknown': unknown,
  if (accepted) 'sequence': 9,
  if (canceled) 'canceled': true,
};

class ManagementPortFixture extends PortFixture {
  ManagementPortFixture() {
    advertisedOperations = {...PortFixture.operations, ...managementOperations};
    deviceExists = true;
  }
  Map<String, Object?> pendingManagement = info();
  List<Map<String, Object?>> rows = [
    {
      'deviceId': 'a' * 64,
      'role': 'admin',
      'expiresAt': 0,
      'keyVersion': '1',
      'grantGeneration': '1',
    },
    {
      'deviceId': target,
      'role': 'rw',
      'expiresAt': 0,
      'keyVersion': '1',
      'grantGeneration': '2',
    },
  ];
  final managementCalls = <(String, Map<String, String>)>[];
  String? id;
  String? failPrepare;
  bool retryUnknown = false,
      acceptedNotApplied = false,
      cancelReceiptLost = false,
      canceled = false;
  bool selfDemotion = false, invalidated = false;
  Completer<Map<String, Object?>>? delayedPrepare, delayedRetry, delayedDevices;
  @override
  Future<Map<String, Object?>> execute(
    String endpoint,
    String op,
    Map<String, String> fields,
  ) async {
    if (!managementOperations.contains(op)) {
      return super.execute(endpoint, op, fields);
    }
    managementCalls.add((op, Map.of(fields)));
    switch (op) {
      case 'managementInfo':
        return success(pendingManagement);
      case 'managementDevices':
        if (delayedDevices != null) return delayedDevices!.future;
        return success(rows);
      case 'prepareDeviceGrant':
      case 'prepareOtherDeviceRevocation':
        if (failPrepare == 'AUTH_CANCELLED') {
          throw PlatformException(code: failPrepare!);
        }
        id = fields['id'];
        pendingManagement = info(
          id: id!,
          state: 'prepared',
          kind: op == 'prepareDeviceGrant' ? 'grant' : 'revoke',
          subject: fields['subjectDeviceId']!,
        );
        if (delayedPrepare != null) return delayedPrepare!.future;
        if (failPrepare != null) throw PlatformException(code: failPrepare!);
        return success(pendingManagement);
      case 'retryManagement':
        if (invalidated) {
          return {
            'version': 1,
            'experimental': true,
            'ok': false,
            'code': 'TRUST_INVALIDATED',
            'retrySameId': true,
            'data': result('', accepted: false, applied: false),
          };
        }
        expect(fields['id'], id); // 原ID，不依据当前权限值猜成功。
        if (delayedRetry != null) return delayedRetry!.future;
        if (canceled) {
          return success(
            result(id!, accepted: false, applied: false, canceled: true),
          );
        }
        if (retryUnknown || acceptedNotApplied) {
          pendingManagement = {
            ...pendingManagement,
            'state': acceptedNotApplied ? 'accepted-not-applied' : 'pending',
            'attempted': true,
            if (acceptedNotApplied) 'sequence': 9,
          };
          return {
            'version': 1,
            'experimental': true,
            'ok': false,
            'code': 'PENDING',
            'retrySameId': true,
            'data': result(
              id!,
              accepted: acceptedNotApplied,
              applied: false,
              unknown: !acceptedNotApplied,
            ),
          };
        }
        pendingManagement = info();
        if (selfDemotion) {
          ((view['environments'] as List).single as Map)['role'] = 'RO';
        }
        return success(result(id!));
      case 'cancelManagement':
        expect(fields['id'], id);
        pendingManagement = info();
        canceled = true;
        if (cancelReceiptLost) {
          throw PlatformException(code: 'GO_OR_KEYSTORE_REJECTED');
        }
        return success();
    }
    throw StateError('fixture only');
  }
}

Future<(VaultController, NativeVaultGateway, ManagementPortFixture)> setup({
  ManagementPortFixture? fixture,
  Set<String>? evidence,
  bool unlock = true,
}) async {
  final f = fixture ?? ManagementPortFixture();
  final g = NativeVaultGateway(
    experimentalOptIn: true,
    port: f,
    verifiedManagementOperations: evidence ?? managementOperations,
    now: () => clock,
    inspector: (_) async => const InstanceDescriptor(
      initialRegistrationAvailable: false,
      allowRegistration: false,
      emailVerificationRequired: false,
    ),
  );
  final c = VaultController(gateway: g, now: () => clock);
  await c.initialize();
  await c.connectServer('https://fixture.example.invalid');
  if (unlock) await c.unlockSavedDevice();
  return (c, g, f);
}

Future<void> loaded(VaultController c) async {
  await c.loadManagedDevices(env);
  expect(c.management.devices.length, 2);
}

Future<void> grant(
  VaultController c, {
  String subject = target,
  ManagedRole role = ManagedRole.readOnly,
}) => c.prepareManagedDeviceGrant(
  environmentId: env,
  subjectDeviceId: subject,
  role: role,
  expiry: const ManagementExpiry.untilRevoked(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('严格管理DTO区分omitempty/代际/重复设备/请求期限和接受未应用', () {
    expect(decodeManagementInfo(info()).phase, ManagementPhase.idle);
    expect(
      decodeManagementInfo(info(id: 'original', state: 'prepared'))
          .requestExpiresAt,
      isNull,
    );
    expect(
      decodeManagementInfo(
        info(id: 'original', state: 'prepared', kind: 'revoke'),
      ).requestExpiresAt,
      isNotNull,
    );
    for (final invalid in [
      {...info(), 'id': 'unused'},
      {...info(id: 'original', state: 'prepared'), 'attempted': true},
      {...info(id: 'original', state: 'accepted-not-applied'), 'sequence': '9'},
      {...info(id: 'original', state: 'prepared'), 'role': 'admin'},
    ]) {
      expect(
        () => decodeManagementInfo(invalid),
        throwsA(isA<GatewayFailure>()),
      );
    }
    final rows = ManagementPortFixture().rows;
    expect(decodeManagementDevices(rows, env, 'a' * 64).first.current, true);
    expect(
      () => decodeManagementDevices([...rows, rows.last], env, 'a' * 64),
      throwsA(isA<GatewayFailure>()),
    );
    expect(
      () => decodeManagementResult(result('other'), 'original'),
      throwsA(isA<GatewayFailure>()),
    );
    expect(
      () => decodeManagementResult(
        result('original', accepted: false),
        'original',
      ),
      throwsA(isA<GatewayFailure>()),
    );
  });
  test('现有NativeWorkflowAdapter精确映射六意图，无公钥/封套输入', () async {
    const channel = MethodChannel('org.harmoniavault/native/v1');
    final calls = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'executeWorkflow');
          final body = jsonDecode(call.arguments as String) as Map;
          calls.add(body);
          return jsonEncode({
            'version': 1,
            'experimental': true,
            'ok': true,
            'data': info(),
          });
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    const a = NativeWorkflowAdapter('https://fixture.example.invalid');
    await a.managementDevices(env);
    await a.prepareDeviceGrant(
      environmentId: env,
      subjectDeviceId: target,
      role: 'ro',
      expiresAt: '0',
      id: 'original',
    );
    await a.prepareOtherDeviceRevocation(
      environmentId: env,
      subjectDeviceId: target,
      id: 'original-revoke',
    );
    await a.managementInfo();
    await a.retryManagement('original');
    await a.cancelManagement('original');
    expect(calls.map((c) => c['operation']).toSet(), managementOperations);
    expect(calls[1].keys.toSet(), {
      'version',
      'endpoint',
      'operation',
      'environmentId',
      'subjectDeviceId',
      'role',
      'expiresAt',
      'id',
    });
  });
  test('runtime广告不授管理能力，默认独立管理证据关闭', () async {
    final (c, g, f) = await setup(evidence: {});
    addTearDown(c.dispose);
    expect(g.managementCapabilities, isEmpty);
    await c.loadManagedDevices(env);
    expect(f.managementCalls, isEmpty);
  });
  test('管理准备≠提交，无乐观改权；完成后只通过正式restore/pull更新', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await loaded(c);
    await grant(c);
    final id = c.management.operation.id;
    expect(id, isNotEmpty);
    expect(c.management.operation.phase, ManagementPhase.prepared);
    expect(f.managementCalls.where((x) => x.$1 == 'retryManagement'), isEmpty);
    expect(c.canEnterVault, false);
    expect(c.management.allows(ManagementAction.cancelOriginal), true);
    expect(c.management.devices, isEmpty);
    await c.submitOriginalManagement();
    expect(c.management.operation.phase, ManagementPhase.applied);
    expect(c.canEnterVault, true);
    expect(f.managementCalls.last.$1, 'retryManagement');
    expect(f.managementCalls.last.$2, {'id': id});
    expect(f.calls.map((x) => x.$1).toList().reversed.take(3).toList(), [
      'pull',
      'businessPendingInfo',
      'restoreSession',
    ]);
  });
  test('连续点击只prepare一个ID，在途gateway也拒绝第二新意图', () async {
    final (c, g, f) = await setup();
    addTearDown(c.dispose);
    await loaded(c);
    f.delayedPrepare = Completer();
    final first = grant(c);
    await Future<void>.delayed(Duration.zero);
    final original = f.id;
    await grant(c);
    await expectLater(
      g.prepareDeviceGrant(
        environmentId: env,
        subjectDeviceId: target,
        role: ManagedRole.admin,
        expiry: const ManagementExpiry.untilRevoked(),
      ),
      throwsA(isA<GatewayFailure>()),
    );
    expect(
      f.managementCalls.where((x) => x.$1 == 'prepareDeviceGrant').length,
      1,
    );
    f.delayedPrepare!.complete(f.success(f.pendingManagement));
    await first;
    expect(c.management.operation.id, original);
  });
  test('unknown与accepted-not-applied只原ID续办，不可cancel或新prepare', () async {
    for (final accepted in [false, true]) {
      final (c, _, f) = await setup();
      await loaded(c);
      await grant(c);
      final original = c.management.operation.id;
      f.retryUnknown = !accepted;
      f.acceptedNotApplied = accepted;
      await c.submitOriginalManagement();
      expect(c.management.operation.id, original);
      expect(c.management.operation.sequence, accepted ? 9 : 0);
      expect(c.management.allows(ManagementAction.cancelOriginal), false);
      expect(c.management.allows(ManagementAction.prepareGrant), false);
      final count = f.managementCalls.length;
      await c.cancelOriginalManagement();
      expect(f.managementCalls.length, count);
      f.retryUnknown = false;
      f.acceptedNotApplied = false;
      await c.submitOriginalManagement();
      expect(c.management.operation.phase, ManagementPhase.applied);
      expect(
        f.managementCalls
            .where((x) => x.$1 == 'retryManagement')
            .map((x) => x.$2['id'])
            .toSet(),
        {original},
      );
      c.dispose();
    }
  });
  test('prepare保存回应未知保原ID；info确认prepared后才允许取消', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await loaded(c);
    f.failPrepare = 'GO_OR_KEYSTORE_REJECTED';
    await grant(c);
    final id = f.id;
    expect(c.management.operation.id, id);
    expect(c.management.operation.phase, ManagementPhase.unknown);
    await c.inspectDeviceManagement();
    expect(c.management.operation.phase, ManagementPhase.prepared);
    await c.cancelOriginalManagement();
    expect(c.management.operation.phase, ManagementPhase.cancelled);
    expect(c.canEnterVault, true);
    expect(
      f.managementCalls
          .where((x) => x.$1 == 'cancelManagement')
          .single
          .$2['id'],
      id,
    );
  });
  test('认证取消明确未dispatch，不把新ID锁成云端未知；输入错误零原生调用', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await loaded(c);
    f.failPrepare = 'AUTH_CANCELLED';
    await grant(c);
    expect(c.management.operation.unresolved, false);
    expect(c.canEnterVault, true);
    final count = f.managementCalls.length;
    await c.prepareManagedDeviceGrant(
      environmentId: env,
      subjectDeviceId: target,
      role: ManagedRole.ungranted,
      expiry: const ManagementExpiry.untilRevoked(),
    );
    await c.prepareManagedDeviceGrant(
      environmentId: env,
      subjectDeviceId: target,
      role: ManagedRole.none,
      expiry: ManagementExpiry.until(clock.add(const Duration(days: 1))),
    );
    expect(f.managementCalls.length, count);
  });
  test('本机自降权后正式pull变RO，旧Admin管理列表/入口不能复活', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await loaded(c);
    await grant(c, subject: 'a' * 64);
    f.selfDemotion = true;
    await c.submitOriginalManagement();
    expect(c.environments.single.role, AccessRole.readOnly);
    expect(c.management.devices, isEmpty);
    expect(c.management.allows(ManagementAction.loadDevices), false);
    final count = f.managementCalls.length;
    await c.loadManagedDevices(env);
    expect(f.managementCalls.length, count);
  });
  test('其它设备全局撤销需明确确认，不能把本机/未选目标当其它设备', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await loaded(c);
    final count = f.managementCalls.length;
    await c.prepareManagedDeviceRevocation(
      environmentId: env,
      subjectDeviceId: target,
      destructiveConfirmed: false,
    );
    await c.prepareManagedDeviceRevocation(
      environmentId: env,
      subjectDeviceId: 'a' * 64,
      destructiveConfirmed: true,
    );
    expect(f.managementCalls.length, count);
    await c.prepareManagedDeviceRevocation(
      environmentId: env,
      subjectDeviceId: target,
      destructiveConfirmed: true,
    );
    expect(c.management.operation.kind, 'revoke');
    expect(c.management.operation.requestExpiresAt, isNotNull);
    expect(f.managementCalls.last.$1, 'prepareOtherDeviceRevocation');
    expect(c.management.operation.phase, ManagementPhase.prepared);
  });
  test('cancel保存回应丢失后只原ID查询，canceled history恢复并不伪applied', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await loaded(c);
    await grant(c);
    final id = f.id;
    f.cancelReceiptLost = true;
    await c.cancelOriginalManagement();
    expect(c.management.operation.phase, ManagementPhase.unknown);
    await c.submitOriginalManagement();
    expect(c.management.operation.phase, ManagementPhase.cancelled);
    expect(c.management.operation.id, id);
    expect(c.management.operation.sequence, 0);
  });
  test('cold pending无需伪trusted，原ID续办完成才正式恢复真实会话', () async {
    final f = ManagementPortFixture()
      ..id = 'original-cold'
      ..pendingManagement = info(id: 'original-cold', state: 'pending');
    final (c, _, _) = await setup(fixture: f, unlock: false);
    addTearDown(c.dispose);
    await c.inspectDeviceManagement();
    expect(c.sessionStage, SessionStage.signedOut);
    expect(c.canEnterVault, false);
    expect(c.management.operation.id, 'original-cold');
    expect(c.navigate(VaultPage.devices), true);
    await c.submitOriginalManagement();
    expect(c.sessionStage, SessionStage.trusted);
    expect(c.canEnterVault, true);
  });
  test('Logout退役在途prepare，晚到prepared不能重新注入原账号管理状态', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await loaded(c);
    f.delayedPrepare = Completer();
    final preparing = grant(c);
    await Future<void>.delayed(Duration.zero);
    await c.logout();
    f.delayedPrepare!.complete(f.success(f.pendingManagement));
    await preparing;
    expect(c.sessionStage, SessionStage.signedOut);
    expect(c.management.operation.unresolved, false);
    expect(c.management.devices, isEmpty);
  });
  test('管理中收到实际TRUST_INVALIDATED清会话与原管理材料，不保留可续办假状态', () async {
    final (c, g, f) = await setup();
    addTearDown(c.dispose);
    await loaded(c);
    await grant(c);
    f.invalidated = true;
    await c.submitOriginalManagement();
    expect(c.sessionStage, SessionStage.signedOut);
    expect(c.canEnterVault, false);
    expect(c.management.operation.unresolved, false);
    expect(g.managementOperation.unresolved, false);
    expect(c.management.devices, isEmpty);
  });
  test('管理读取在途进入后台清旧明文，迟到失效结果不因resumed显示缓存', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    f.delayedDevices = Completer();
    final reading = c.loadManagedDevices(env);
    await Future<void>.delayed(Duration.zero);
    c.setForeground(false);
    f.delayedDevices!.complete({
      'version': 1,
      'experimental': true,
      'ok': false,
      'code': 'TRUST_INVALIDATED',
    });
    await reading;
    c.setForeground(true);
    expect(c.canEnterVault, false);
    expect(c.environments, isEmpty);
    expect(c.management.devices, isEmpty);
  });
  test('DAG选择来源仍关闭旧管理六入口，不因runtime和证据都存在降级', () async {
    final f = DAGPortFixture()
      ..advertisedOperations = {
        ...PortFixture.operations,
        ...managementOperations,
        'openDAGRecoveryOwner',
      };
    final g = NativeVaultGateway(
      experimentalOptIn: true,
      port: f,
      verifiedDAGOperations: {'openDAGRecoveryOwner'},
      verifiedManagementOperations: managementOperations,
      inspector: (_) async => const InstanceDescriptor(
        initialRegistrationAvailable: false,
        allowRegistration: false,
        emailVerificationRequired: false,
      ),
    );
    await g.initialize('');
    await g.inspectInstance('https://fixture.example.invalid');
    g.bindVerifiedServer('https://fixture.example.invalid');
    await g.executeRecovery('openDAGRecoveryOwner', {}, Uint8List(32));
    expect(g.managementCapabilities, isEmpty);
    await expectLater(g.inspectManagement(), throwsA(isA<GatewayFailure>()));
    expect(f.calls.where((x) => managementOperations.contains(x.$1)), isEmpty);
  });
}
