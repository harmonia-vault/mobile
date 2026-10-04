import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/dag_business/dag_business_gateway.dart';
import 'package:harmonia_mobile/dag_business/dag_environment_gateway.dart';
import 'package:harmonia_mobile/native/native_dag_environment_adapter.dart';
import 'package:harmonia_mobile/native/native_dag_recovery_adapter.dart';
import 'package:harmonia_mobile/native/native_vault_gateway.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'dag_business_routing_test.dart' as vb;
import 'recovery_business_test.dart' as rb;

// 仅合成传输/控制器安全合同，不证明 Go ABI、Android认证或用户点击。
Map<String, Object?> metadata(
  String id, {
  String op = 'rename',
  String env = 'env-fixture',
  String seq = '14',
  bool applied = false,
}) => {
  'requestId': id,
  'operation': op,
  'environmentId': env,
  'sequence': seq,
  'applied': applied,
};
Map<String, Object?> envelope(String op, Object data, {bool ok = true}) => {
  'version': 1,
  'profile': 'issuer-recovery-dag-v1',
  'operation': op,
  'ok': ok,
  'trustedDevice': ok && op != 'pendingDAGEnvironments',
  'data': data,
  if (!ok) 'error': {'code': 'ORIGINAL_RETRY_REQUIRED', 'retryOriginal': true},
};
Map<String, Object?> successful(
  String op,
  String id, {
  String kind = 'rename',
  String env = 'env-fixture',
  String generation = '1',
  String checkpoint = '14',
}) => envelope(op, {
  'environment': metadata(id, op: kind, env: env, applied: true),
  'source': vb.source(
    role: 'Admin',
    generation: generation,
    checkpoint: checkpoint,
  ),
});

class EnvironmentPort extends vb.BusinessPort
    implements NativeDAGEnvironmentPort {
  bool environmentCompiled = true,
      environmentUnknown = false,
      malformed = false;
  int environmentProfiles = 0;
  String? environmentFailure;
  String environmentGeneration = '1', environmentCheckpoint = '14';
  final environmentCalls = <(String, Map<String, String>)>[];
  List<Map<String, Object?>> environmentJournal = [];
  Uint8List? nameReceived;
  Completer<Map<String, Object?>>? environmentDelay;
  EnvironmentPort() {
    role = 'Admin';
  }
  @override
  Future<Map<String, Object?>> capabilities() async => {
    ...await super.capabilities(),
    'nativeDAGEnvironment': environmentCompiled,
  };
  @override
  Future<Map<String, Object?>> dagEnvironmentProfile() async {
    environmentProfiles++;
    return {
      'version': 1,
      'profile': 'issuer-recovery-dag-v1',
      'operations': dagEnvironmentOperations.toList()..sort(),
    };
  }

  @override
  Future<Map<String, Object?>> executeDAGEnvironment(
    String endpoint,
    String op,
    Map<String, String> fields,
    Uint8List name,
  ) async {
    environmentCalls.add((op, Map.of(fields)));
    nameReceived = name;
    if (environmentFailure != null) {
      throw PlatformException(code: environmentFailure!);
    }
    if (environmentDelay != null) return environmentDelay!.future;
    if (op == 'pendingDAGEnvironments') {
      return envelope(op, {
        'pending': environmentJournal,
        'trustedDevice': false,
        if (malformed) 'extra': true,
      });
    }
    final id = fields['requestId']!;
    final previous = environmentJournal.where((r) => r['requestId'] == id);
    final kind = op == 'retryDAGEnvironment'
        ? previous.single['operation'] as String
        : op.replaceFirst('DAGEnvironment', '');
    final env = op == 'retryDAGEnvironment'
        ? previous.single['environmentId'] as String
        : fields['environmentId'] ?? 'env-created';
    if (environmentUnknown) {
      final row = metadata(id, op: kind, env: env, seq: '0');
      environmentJournal = [
        ...environmentJournal.where((r) => r['requestId'] != id),
        row,
      ];
      return envelope(op, {'original': row, 'trustedDevice': false}, ok: false);
    }
    environmentJournal = environmentJournal
        .where((r) => r['requestId'] != id)
        .toList();
    checkpoint = environmentCheckpoint;
    return {
      ...successful(
        op,
        id,
        kind: kind,
        env: env,
        generation: environmentGeneration,
        checkpoint: environmentCheckpoint,
      ),
      if (malformed) 'extra': true,
    };
  }
}

Future<(VaultController, NativeVaultGateway, EnvironmentPort)> ready({
  EnvironmentPort? fixture,
  Set<String>? evidence,
}) async {
  final f = fixture ?? EnvironmentPort();
  f.deviceExists = true;
  f.e = rb.enrolled(exists: true, applied: true);
  final g = NativeVaultGateway(
    experimentalOptIn: true,
    port: f,
    verifiedDAGOperations: dagRecoveryFields.keys.toSet(),
    verifiedDAGBusinessOperations: dagBusinessOperations,
    verifiedDAGEnvironmentOperations: evidence ?? dagEnvironmentOperations,
    inspector: (_) async => const InstanceDescriptor(
      initialRegistrationAvailable: false,
      allowRegistration: false,
      emailVerificationRequired: false,
    ),
  );
  final c = VaultController(gateway: g);
  await c.initialize();
  await c.connectServer(rb.endpoint);
  await c.inspectRecovery();
  await c.restoreRecoveredDevice();
  await c.pullRecoveredDevice();
  return (c, g, f);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('环境独立compiled/profile/verified门：默认关闭，无新增getter或native调用', () async {
    final (c, g, f) = await ready(evidence: {});
    addTearDown(c.dispose);
    expect(f.environmentProfiles, 0);
    expect(g.capabilities.contains('createEnvironment'), false);
    await c.renameEnvironment('env-fixture', '合成');
    expect(f.environmentCalls, isEmpty);
  });
  test('创建需明确Admin选择，不默认第一项；名称RAM分离，四修改不用普通writer/Pull', () async {
    final (c, _, f) = await ready();
    addTearDown(c.dispose);
    expect(c.supports('createEnvironment'), true);
    expect(c.dagEnvironmentAuthorityId, isNull);
    final before = f.environmentCalls.length;
    await c.createEnvironment('合成');
    expect(f.environmentCalls.length, before);
    c.selectDAGEnvironmentAuthority('env-fixture');
    expect(c.dagEnvironmentAuthorityId, 'env-fixture');
    await c.createEnvironment('合成');
    expect(f.environmentCalls.last.$1, 'createDAGEnvironment');
    expect(
      f.environmentCalls.last.$2.keys,
      unorderedEquals(['requestId', 'authorityEnvironmentId']),
    );
    expect(f.nameReceived!.every((b) => b == 0), true);
    expect(c.checkpoint, 14);
    await c.renameEnvironment('env-fixture', '重命名');
    expect(f.environmentCalls.last.$1, 'renameDAGEnvironment');
    await c.rotateEnvironmentKey('env-fixture');
    expect(f.environmentCalls.last.$1, 'rotateDAGEnvironment');
    expect(f.nameReceived, isEmpty);
    await c.deleteEnvironment('env-fixture');
    expect(f.environmentCalls.last.$1, 'deleteDAGEnvironment');
    expect(
      f.calls.where(
        (r) => {
          'createEnvironment',
          'renameEnvironment',
          'deleteEnvironment',
          'rotateEnvironmentKey',
          'pull',
        }.contains(r.$1),
      ),
      isEmpty,
    );
  });
  test('RW/RO无法借其它环境的Admin创建或修改；明确无效选择不保留旧选择', () async {
    for (final role in ['RO', 'RW']) {
      final f = EnvironmentPort()..role = role;
      final (c, _, _) = await ready(fixture: f);
      expect(c.dagEnvironmentAuthorityChoices, isEmpty);
      c.selectDAGEnvironmentAuthority('env-fixture');
      expect(c.dagEnvironmentAuthorityId, isNull);
      final n = f.environmentCalls.length;
      await c.renameEnvironment('env-fixture', '合成');
      await c.createEnvironment('合成');
      await c.rotateEnvironmentKey('env-fixture');
      expect(f.environmentCalls.length, n);
      c.dispose();
    }
  });
  test('原环境unknown阻止两域新写，查询/冷恢复仅原ID续办，成功应用同次source', () async {
    final (c, _, f) = await ready();
    addTearDown(c.dispose);
    f.environmentUnknown = true;
    await c.renameEnvironment('env-fixture', '合成');
    final id = c.businessPending.single.id;
    expect(c.canEnterVault, false);
    final n = f.environmentCalls.length;
    await c.renameEnvironment('env-fixture', '另名');
    await c.setVariable('env-fixture', 'SYNTHETIC', 'only');
    expect(f.environmentCalls.length, n);
    final (cold, _, _) = await ready(fixture: f);
    addTearDown(cold.dispose);
    expect(cold.businessPending.single.id, id);
    expect(cold.canEnterVault, false);
    f.environmentUnknown = false;
    await cold.retryBusinessPending(id);
    expect(f.environmentCalls.last.$1, 'retryDAGEnvironment');
    expect(f.environmentCalls.last.$2, {'requestId': id});
    expect(f.nameReceived, isEmpty);
    expect(cold.canEnterVault, true);
    expect(cold.businessPending, isEmpty);
  });
  test('已调native但未知异常保原RAM意图，必须先query后retry，同ID无替代名称', () async {
    final (c, _, f) = await ready();
    addTearDown(c.dispose);
    f.environmentFailure = 'LOCAL_PROTECTION_PERSISTENCE';
    await c.renameEnvironment('env-fixture', '合成');
    final id = c.businessPending.single.id;
    expect(c.canEnterVault, false);
    final n = f.environmentCalls.length;
    await c.retryBusinessPending(id);
    expect(f.environmentCalls.length, n);
    f.environmentFailure = null;
    f.environmentJournal = [metadata(id, seq: '0')];
    await c.queryBusinessPending();
    await c.retryBusinessPending(id);
    expect(f.environmentCalls.last.$1, 'retryDAGEnvironment');
    expect(f.environmentCalls.last.$2, {'requestId': id});
    expect(c.canEnterVault, true);
  });
  test('变量pending与环境pending合并但不串路由，重复跨域ID拒绝', () async {
    final f = EnvironmentPort()
      ..durablePending = [vb.original('variable-original')]
      ..environmentJournal = [metadata('environment-original')];
    final (c, _, _) = await ready(fixture: f);
    addTearDown(c.dispose);
    expect(c.businessPending.length, 2);
    await c.retryBusinessPending('environment-original');
    expect(f.environmentCalls.last.$1, 'retryDAGEnvironment');
    expect(c.canEnterVault, false);
    await c.retryBusinessPending('variable-original');
    expect(f.businessCalls.last.$1, 'retryDAGWrite');
    expect(c.canEnterVault, true);
    final duplicate = EnvironmentPort()
      ..durablePending = [vb.original('same-original')]
      ..environmentJournal = [metadata('same-original')];
    final (bad, _, _) = await ready(fixture: duplicate);
    addTearDown(bad.dispose);
    expect(bad.canEnterVault, false);
  });
  test('pending已applied历史不授trust或阻断新写；AUTH_CANCELLED保留原日志', () async {
    final f = EnvironmentPort()
      ..environmentJournal = [metadata('done-original', applied: true)];
    final (c, _, _) = await ready(fixture: f);
    addTearDown(c.dispose);
    expect(c.canEnterVault, true);
    expect(c.businessPending.single.canRetry, false);
    f.environmentJournal = [metadata('still-original')];
    await c.queryBusinessPending();
    f.environmentFailure = 'AUTH_CANCELLED';
    await c.retryBusinessPending('still-original');
    expect(c.businessPending.single.id, 'still-original');
    expect(c.canEnterVault, false);
  });
  test('错误DTO/账号绑定/倒退/明确失效不应用旧明文', () async {
    for (final mode in ['malformed', 'generation', 'rollback', 'revoked']) {
      final (c, _, f) = await ready();
      if (mode == 'malformed') f.malformed = true;
      if (mode == 'generation') f.environmentGeneration = '2';
      if (mode == 'rollback') f.environmentCheckpoint = '12';
      if (mode == 'revoked') f.environmentFailure = 'TRUST_INVALIDATED';
      await c.renameEnvironment('env-fixture', '合成');
      expect(c.canEnterVault, false);
      expect(c.environments, isEmpty);
      if (mode == 'revoked') expect(c.sessionStage, SessionStage.signedOut);
      c.dispose();
    }
  });
  test('认证inactive返回须同epoch resumed，paused晚到source不能复活', () async {
    for (final paused in [false, true]) {
      final (c, _, f) = await ready();
      f.environmentDelay = Completer();
      final changing = c.renameEnvironment('env-fixture', '合成');
      await Future<void>.delayed(Duration.zero);
      final id = f.environmentCalls.last.$2['requestId']!;
      c.onLifecycleState(
        paused ? AppLifecycleState.paused : AppLifecycleState.inactive,
      );
      f.environmentDelay!.complete(successful('renameDAGEnvironment', id));
      await Future<void>.delayed(Duration.zero);
      expect(c.environments, isEmpty);
      c.onLifecycleState(AppLifecycleState.resumed);
      await changing;
      expect(c.canEnterVault, !paused);
      c.dispose();
    }
  });
  test('strict metadata五字段、seq/applied、原ID/target、unknown不含source', () {
    for (final row in [
      metadata('x', seq: '00'),
      metadata('x', seq: '9007199254740992'),
      metadata('x', seq: '0', applied: true),
      {...metadata('x'), 'name': 'SYNTHETIC'},
    ]) {
      expect(
        () => decodeDAGEnvironment(
          'pendingDAGEnvironments',
          envelope('pendingDAGEnvironments', {
            'pending': [row],
            'trustedDevice': false,
          }),
        ),
        throwsA(isA<GatewayFailure>()),
      );
    }
    expect(
      () => decodeDAGEnvironment(
        'renameDAGEnvironment',
        successful('renameDAGEnvironment', 'other'),
        originalId: 'x',
      ),
      throwsA(isA<GatewayFailure>()),
    );
    expect(
      () => decodeDAGEnvironment(
        'renameDAGEnvironment',
        successful('renameDAGEnvironment', 'x', env: 'another'),
        originalId: 'x',
        environmentId: 'env-fixture',
      ),
      throwsA(isA<GatewayFailure>()),
    );
    final raw = envelope('renameDAGEnvironment', {
      'original': metadata('x', seq: '0'),
      'trustedDevice': false,
    }, ok: false);
    expect(
      decodeDAGEnvironment('renameDAGEnvironment', raw, originalId: 'x').source,
      isNull,
    );
    expect(
      () => decodeDAGEnvironment('renameDAGEnvironment', {
        ...raw,
        'data': {
          'original': metadata('x'),
          'trustedDevice': false,
          'source': vb.source(),
        },
      }, originalId: 'x'),
      throwsA(isA<GatewayFailure>()),
    );
  });
  test('MethodChannel精确command/name字节，非法UTF8/NUL/长度/替代retry字段零发送并清理', () async {
    const channel = MethodChannel('org.harmoniavault/native/v1');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      expect(call.method, 'executeDAGEnvironment');
      final args = call.arguments as Map;
      expect(args.keys, unorderedEquals(['command', 'name']));
      final command = jsonDecode(args['command'] as String) as Map;
      expect(command.containsKey('name'), false);
      return jsonEncode(successful('renameDAGEnvironment', 'original'));
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    const a = NativeDAGEnvironmentAdapter();
    final fields = {'requestId': 'original', 'environmentId': 'env-fixture'};
    final name = Uint8List.fromList(utf8.encode('合成名称'));
    await a.executeDAGEnvironment(
      rb.endpoint,
      'renameDAGEnvironment',
      fields,
      name,
    );
    expect(name.every((b) => b == 0), true);
    for (final bytes in [
      Uint8List.fromList([255]),
      Uint8List.fromList([0]),
      Uint8List.fromList(utf8.encode('x' * 121)),
      Uint8List(481),
    ]) {
      await expectLater(
        a.executeDAGEnvironment(
          rb.endpoint,
          'renameDAGEnvironment',
          fields,
          bytes,
        ),
        throwsA(isA<GatewayFailure>()),
      );
      expect(bytes.every((b) => b == 0), true);
    }
    await expectLater(
      a.executeDAGEnvironment(
        rb.endpoint,
        'retryDAGEnvironment',
        fields,
        Uint8List(0),
      ),
      throwsA(isA<GatewayFailure>()),
    );
    expect(calls, 1);
  });
}
