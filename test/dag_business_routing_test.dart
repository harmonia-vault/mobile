import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/dag_business/dag_business_gateway.dart';
import 'package:harmonia_mobile/native/native_dag_business_adapter.dart';
import 'package:harmonia_mobile/native/native_dag_recovery_adapter.dart';
import 'package:harmonia_mobile/native/native_vault_gateway.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'recovery_business_test.dart' as rb;

// 合成来源、传输与控制层测试；不是Go/JNI/强认证/Flutter用户点击证据。
Map<String, Object?> source({
  String generation = '1',
  String checkpoint = '14',
  String role = 'RW',
}) {
  final result = rb.trusted(generation: generation, checkpoint: checkpoint);
  final view = result['view'] as Map;
  final rows = view['environments'] as List;
  (rows.single as Map)['role'] = role;
  return result;
}

Map<String, Object?> original(
  String id, {
  String operation = 'put',
  int accepted = 1,
  bool canceled = false,
}) => {
  'requestId': id,
  'operation': operation,
  'environmentId': 'env-fixture',
  'total': 1,
  'accepted': accepted,
  'applied': false,
  'canceled': canceled,
  'sequences': [accepted == 1 ? '14' : '0'],
};
Map<String, Object?> result(String op, Object data, {bool ok = true}) => {
  'version': 1,
  'profile': 'issuer-recovery-dag-v1',
  'operation': op,
  'ok': ok,
  'trustedDevice': ok && op != 'pendingDAGWrites',
  'data': data,
  if (!ok) 'error': {'code': 'ORIGINAL_RETRY_REQUIRED', 'retryOriginal': true},
};
Map<String, Object?> applied(
  String op,
  String id, {
  String generation = '1',
  String checkpoint = '14',
}) => result(op, {
  'write': {
    'requestId': id,
    'total': 1,
    'accepted': 1,
    'applied': true,
    'sequences': ['14'],
  },
  'source': source(generation: generation, checkpoint: checkpoint),
});

class BusinessPort extends rb.DAGPortFixture implements NativeDAGBusinessPort {
  bool compiled = true, unknown = false;
  bool malformedWrite = false, malformedPending = false;
  String? failure;
  String resultGeneration = '1', resultCheckpoint = '14', role = 'RW';
  int profileCalls = 0;
  final businessCalls = <(String, Map<String, String>)>[];
  List<Map<String, Object?>> durablePending = [];
  Uint8List? received;
  Completer<Map<String, Object?>>? delay;
  @override
  Future<Map<String, Object?>> capabilities() async => {
    ...await super.capabilities(),
    'nativeDAGBusiness': compiled,
  };
  @override
  Future<Map<String, Object?>> dagBusinessProfile() async {
    profileCalls++;
    return {
      'version': 1,
      'profile': 'issuer-recovery-dag-v1',
      'operations': dagBusinessOperations.toList()..sort(),
    };
  }

  @override
  Future<Map<String, Object?>> executeDAGRecovery(
    String ep,
    String op,
    Map<String, String> fields,
    Uint8List code,
  ) async {
    final raw = await super.executeDAGRecovery(ep, op, fields, code);
    if (raw['trustedDevice'] == true) {
      raw['data'] = source(checkpoint: checkpoint, role: role);
    }
    return raw;
  }

  @override
  Future<Map<String, Object?>> executeDAGBusiness(
    String ep,
    String op,
    Map<String, String> fields,
    Uint8List value,
  ) async {
    businessCalls.add((op, Map.of(fields)));
    received = value;
    if (failure != null) throw PlatformException(code: failure!);
    if (delay != null) return delay!.future;
    if (op == 'pendingDAGWrites') {
      return result(op, {
        'pending': durablePending,
        'trustedDevice': false,
        if (malformedPending) 'unexpected': 'SYNTHETIC',
      });
    }
    final id = fields['requestId']!;
    if (unknown) {
      final row = original(
        id,
        operation: op == 'deleteDAGVariable' ? 'delete' : 'put',
      );
      durablePending = [
        ...durablePending.where((r) => r['requestId'] != id),
        row,
      ];
      return result(op, {'original': row, 'trustedDevice': false}, ok: false);
    }
    durablePending = durablePending.where((r) => r['requestId'] != id).toList();
    checkpoint = resultCheckpoint;
    return {
      ...applied(
        op,
        id,
        generation: resultGeneration,
        checkpoint: resultCheckpoint,
      ),
      if (malformedWrite) 'unexpected': 'SYNTHETIC',
    };
  }
}

Future<(VaultController, NativeVaultGateway, BusinessPort)> ready({
  BusinessPort? fixture,
  Set<String>? evidence,
}) async {
  final f = fixture ?? BusinessPort();
  f.deviceExists = true;
  f.e = rb.enrolled(exists: true, applied: true);
  final g = NativeVaultGateway(
    experimentalOptIn: true,
    port: f,
    verifiedDAGOperations: dagRecoveryFields.keys.toSet(),
    verifiedDAGBusinessOperations: evidence ?? dagBusinessOperations,
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
  test('独立profile/compiled/verified三门；默认空且不调用新getter', () async {
    for (final mode in ['empty', 'uncompiled', 'nostrong', 'missingretry']) {
      final f = BusinessPort();
      if (mode == 'uncompiled') f.compiled = false;
      if (mode == 'nostrong') f.systemStrong = false;
      final evidence = mode == 'empty'
          ? <String>{}
          : mode == 'missingretry'
          ? {'putDAGVariable', 'pendingDAGWrites'}
          : dagBusinessOperations;
      final (c, g, _) = await ready(fixture: f, evidence: evidence);
      expect(g.capabilities.contains('setVariable'), false);
      if (mode == 'empty' || mode == 'uncompiled') expect(f.profileCalls, 0);
      await c.setVariable('env-fixture', 'SYNTHETIC', 'test-only');
      expect(f.businessCalls.where((x) => x.$1 == 'putDAGVariable'), isEmpty);
      c.dispose();
    }
  });
  test('已验证DAG变量写删专用路由，应用同次FullView，无ordinary writer/Pull', () async {
    final (c, g, f) = await ready();
    addTearDown(c.dispose);
    expect(c.supports('setVariable'), true);
    final pulls = f.dagCalls
        .where((x) => x.$1 == 'pullDAGRecoveredDevice')
        .length;
    await c.setVariable('env-fixture', 'SYNTHETIC', 'test-only');
    expect(f.businessCalls.last.$1, 'putDAGVariable');
    expect(
      f.businessCalls.last.$2.keys,
      unorderedEquals(['requestId', 'environmentId', 'name']),
    );
    expect(f.received!.every((b) => b == 0), true);
    expect(c.checkpoint, 14);
    await c.deleteVariable('env-fixture', 'SYNTHETIC');
    expect(f.businessCalls.last.$1, 'deleteDAGVariable');
    expect(f.received, isEmpty);
    expect(
      f.dagCalls.where((x) => x.$1 == 'pullDAGRecoveredDevice').length,
      pulls,
    );
    expect(
      f.calls.where(
        (x) => {
          'setVariable',
          'deleteVariable',
          'pull',
          'restoreSession',
        }.contains(x.$1),
      ),
      isEmpty,
    );
    await expectLater(
      g.submit(
        const PreviewMutation(
          PreviewOperation.setVariable,
          environmentId: 'env-fixture',
          name: 'SYNTHETIC',
          value: 'test-only',
        ),
      ),
      throwsA(isA<GatewayFailure>()),
    );
    expect(c.supports('createEnvironment'), false);
    await c.reload();
    expect(c.supports('setVariable'), true);
    expect(f.businessCalls.last.$1, 'pendingDAGWrites');
  });
  test('冷恢复先读取原pending，UNKNOWN保原ID并阻断新写；原请求重试不带值/替代字段', () async {
    final (c, g, f) = await ready();
    addTearDown(c.dispose);
    f.unknown = true;
    await c.setVariable('env-fixture', 'SYNTHETIC', 'test-only');
    final id = c.businessPending.single.id;
    expect(c.canEnterVault, false);
    expect(c.businessPending.single.canRetry, true);
    expect(g.capabilities.contains('setVariable'), false);
    final count = f.businessCalls.length;
    await c.setVariable('env-fixture', 'ANOTHER', 'test-only');
    expect(f.businessCalls.length, count);
    final (cold, _, _) = await ready(fixture: f);
    addTearDown(cold.dispose);
    expect(cold.businessPending.single.id, id);
    expect(cold.canEnterVault, false);
    await cold.reload();
    expect(cold.businessPending.single.id, id);
    f.unknown = false;
    await cold.retryBusinessPending(id);
    expect(f.businessCalls.last.$1, 'retryDAGWrite');
    expect(f.businessCalls.last.$2, {'requestId': id});
    expect(f.received, isEmpty);
    expect(cold.canEnterVault, true);
    expect(cold.businessPending, isEmpty);
  });
  test('任意平台保存/网络异常仅保本次RAM原ID标记，先权威query才能retry', () async {
    final (c, _, f) = await ready();
    addTearDown(c.dispose);
    f.failure = 'LOCAL_PROTECTION_PERSISTENCE';
    await c.setVariable('env-fixture', 'SYNTHETIC', 'test-only');
    final id = c.businessPending.single.id;
    expect(c.canEnterVault, false);
    final count = f.businessCalls.length;
    await c.retryBusinessPending(id);
    expect(f.businessCalls.length, count);
    f.failure = null;
    f.durablePending = [original(id)];
    await c.queryBusinessPending();
    expect(c.businessPending.single.id, id);
    expect(c.canEnterVault, false);
    await c.retryBusinessPending(id);
    expect(f.businessCalls.last.$1, 'retryDAGWrite');
    expect(c.canEnterVault, true);
    f.failure = 'LOCAL_PROTECTION_PERSISTENCE';
    await c.setVariable('env-fixture', 'SYNTHETIC', 'test-only');
    f.failure = null;
    f.durablePending = [];
    await c.queryBusinessPending();
    expect(c.canEnterVault, false);
    await c.unlockSavedDevice();
    expect(c.canEnterVault, true);
    expect(c.supports('setVariable'), true);
    expect(f.calls.where((x) => x.$1 == 'restoreSession'), isEmpty);
  });
  test('已核验原ID重试遇未知异常：重新query之前零native重试，之后仍同ID', () async {
    final f = BusinessPort()..durablePending = [original('verified-original')];
    final (c, _, _) = await ready(fixture: f);
    addTearDown(c.dispose);
    expect(c.businessPending.single.id, 'verified-original');
    f.failure = 'REJECTED';
    await c.retryBusinessPending('verified-original');
    expect(f.businessCalls.last.$1, 'retryDAGWrite');
    expect(c.canEnterVault, false);
    final afterUnknown = f.businessCalls.length;
    await c.retryBusinessPending('verified-original');
    expect(f.businessCalls.length, afterUnknown);
    expect(c.businessPending.single.id, 'verified-original');
    f.failure = null;
    await c.queryBusinessPending();
    expect(f.businessCalls.last.$1, 'pendingDAGWrites');
    await c.retryBusinessPending('verified-original');
    expect(f.businessCalls.last.$1, 'retryDAGWrite');
    expect(f.businessCalls.last.$2, {'requestId': 'verified-original'});
    expect(c.canEnterVault, true);
    expect(c.businessPending, isEmpty);
  });
  test('已调用业务的malformed response关闭旧视图，cold restore pending同出口', () async {
    final (c, g, f) = await ready();
    addTearDown(c.dispose);
    f.malformedWrite = true;
    await c.setVariable('env-fixture', 'SYNTHETIC', 'test-only');
    expect(c.canEnterVault, false);
    expect(c.environments, isEmpty);
    expect(g.capabilities.contains('setVariable'), false);
    final id = c.businessPending.single.id;
    final count = f.businessCalls.length;
    await c.retryBusinessPending(id);
    expect(f.businessCalls.length, count);
    f.malformedWrite = false;
    await c.queryBusinessPending();
    expect(c.businessPending, isEmpty);
    expect(c.canEnterVault, false);
    await c.unlockSavedDevice();
    expect(c.canEnterVault, true);
    final coldFixture = BusinessPort()..malformedPending = true;
    final (cold, coldGateway, _) = await ready(fixture: coldFixture);
    addTearDown(cold.dispose);
    expect(cold.canEnterVault, false);
    expect(cold.environments, isEmpty);
    expect(coldGateway.capabilities.contains('setVariable'), false);
  });
  test('两个原ID逐个续办；AUTH_CANCELLED不丢原journal、不解锁', () async {
    final f = BusinessPort()
      ..durablePending = [
        original('first-original'),
        original('second-original'),
      ];
    final (c, _, _) = await ready(fixture: f);
    addTearDown(c.dispose);
    f.failure = 'AUTH_CANCELLED';
    await c.retryBusinessPending('first-original');
    expect(c.businessPending.map((p) => p.id), [
      'first-original',
      'second-original',
    ]);
    expect(c.canEnterVault, false);
    f.failure = null;
    await c.retryBusinessPending('first-original');
    expect(c.businessPending.single.id, 'second-original');
    expect(c.canEnterVault, false);
    await c.retryBusinessPending('second-original');
    expect(c.businessPending, isEmpty);
    expect(c.canEnterVault, true);
  });
  test('wrong binding/rollback/失权硬错误不应用FullView；明确失效清会话', () async {
    for (final mode in ['generation', 'rollback', 'revoked']) {
      final (c, _, f) = await ready();
      if (mode == 'generation') f.resultGeneration = '2';
      if (mode == 'rollback') f.resultCheckpoint = '12';
      if (mode == 'revoked') f.failure = 'TRUST_INVALIDATED';
      await c.setVariable('env-fixture', 'SYNTHETIC', 'test-only');
      expect(c.canEnterVault, false);
      expect(c.environments, isEmpty);
      if (mode == 'revoked') expect(c.sessionStage, SessionStage.signedOut);
      c.dispose();
    }
  });
  test('RO source不写，已取消墓碑不能retry，无pending恢复正常', () async {
    final f = BusinessPort()
      ..role = 'RO'
      ..durablePending = [
        original('canceled-original', accepted: 0, canceled: true),
      ];
    final (c, _, _) = await ready(fixture: f);
    addTearDown(c.dispose);
    final count = f.businessCalls.length;
    await c.setVariable('env-fixture', 'SYNTHETIC', 'test-only');
    await c.retryBusinessPending('canceled-original');
    expect(f.businessCalls.length, count);
    expect(c.canEnterVault, true);
  });
  test('认证inactive返回先遮罩，同epoch resumed才显示业务source', () async {
    final (c, _, f) = await ready();
    addTearDown(c.dispose);
    f.delay = Completer();
    final writing = c.setVariable('env-fixture', 'SYNTHETIC', 'test-only');
    await Future<void>.delayed(Duration.zero);
    final id = f.businessCalls.last.$2['requestId']!;
    c.onLifecycleState(AppLifecycleState.inactive);
    f.delay!.complete(applied('putDAGVariable', id));
    await Future<void>.delayed(Duration.zero);
    expect(c.environments, isEmpty);
    c.onLifecycleState(AppLifecycleState.resumed);
    await writing;
    expect(c.checkpoint, 14);
    expect(c.canEnterVault, true);
  });
  test('paused/logout退休晚到业务source，不复活旧账号或提交替代ID', () async {
    for (final mode in ['paused', 'logout']) {
      final (c, _, f) = await ready();
      f.delay = Completer();
      final writing = c.setVariable('env-fixture', 'SYNTHETIC', 'test-only');
      await Future<void>.delayed(Duration.zero);
      final id = f.businessCalls.last.$2['requestId']!;
      if (mode == 'paused') {
        c.onLifecycleState(AppLifecycleState.paused);
      } else {
        await c.logout();
      }
      f.delay!.complete(applied('putDAGVariable', id));
      await writing;
      c.onLifecycleState(AppLifecycleState.resumed);
      expect(c.canEnterVault, false);
      expect(c.environments, isEmpty);
      expect(f.businessCalls.where((x) => x.$1 == 'putDAGVariable').length, 1);
      c.dispose();
    }
  });
  test('strict响应：未知无view、pending不授trust、原ID/额外secret/seq/重复/伪来源拒绝', () {
    final row = original('write-original');
    final unknown = result('putDAGVariable', {
      'original': row,
      'trustedDevice': false,
    }, ok: false);
    expect(
      decodeDAGBusiness(
        'putDAGVariable',
        unknown,
        originalId: 'write-original',
      ).source,
      isNull,
    );
    for (final bad in [
      {...unknown, 'trustedDevice': true},
      {
        ...unknown,
        'data': {'original': row, 'trustedDevice': false, 'view': source()},
      },
      {
        ...unknown,
        'error': {'code': 'REJECTED', 'retryOriginal': true},
      },
      applied('putDAGVariable', 'other-original'),
      {...applied('putDAGVariable', 'write-original'), 'token': 'SYNTHETIC'},
    ]) {
      expect(
        () => decodeDAGBusiness(
          'putDAGVariable',
          bad,
          originalId: 'write-original',
        ),
        throwsA(isA<GatewayFailure>()),
      );
    }
    final zero = original('zero-original', accepted: 0);
    expect(
      decodeDAGBusiness(
        'pendingDAGWrites',
        result('pendingDAGWrites', {
          'pending': [zero],
          'trustedDevice': false,
        }),
      ).pending!.single.sequences,
      ['0'],
    );
    expect(
      () => decodeDAGBusiness(
        'pendingDAGWrites',
        result('pendingDAGWrites', {
          'pending': [
            {...zero, 'sequences': <String>[]},
          ],
          'trustedDevice': false,
        }),
      ),
      throwsA(isA<GatewayFailure>()),
    );
    final duplicated = result('pendingDAGWrites', {
      'pending': [row, row],
      'trustedDevice': false,
    });
    expect(
      () => decodeDAGBusiness('pendingDAGWrites', duplicated),
      throwsA(isA<GatewayFailure>()),
    );
    final list = decodeDAGBusiness(
      'pendingDAGWrites',
      result('pendingDAGWrites', {
        'pending': [row],
        'trustedDevice': false,
      }),
    ).pending!;
    expect(() => list.clear(), throwsUnsupportedError);
  });
  test('实际MethodChannel仅固定两字段，独立value消费；非法UTF8/NUL/预算/替代retry输入零调用', () async {
    const channel = MethodChannel('org.harmoniavault/native/v1');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      expect(call.method, 'executeDAGBusiness');
      final args = call.arguments as Map;
      expect(args.keys, unorderedEquals(['command', 'value']));
      final command = jsonDecode(args['command'] as String) as Map;
      expect(
        command.keys,
        unorderedEquals([
          'version',
          'endpoint',
          'operation',
          'requestId',
          'environmentId',
          'name',
        ]),
      );
      expect(command.containsKey('value'), false);
      return jsonEncode(applied('putDAGVariable', 'write-original'));
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    const adapter = NativeDAGBusinessAdapter();
    final fields = {
      'requestId': 'write-original',
      'environmentId': 'env-fixture',
      'name': 'SYNTHETIC',
    };
    final value = Uint8List.fromList(utf8.encode('合成'));
    await adapter.executeDAGBusiness(
      rb.endpoint,
      'putDAGVariable',
      fields,
      value,
    );
    expect(value.every((b) => b == 0), true);
    for (final bad in [
      Uint8List.fromList([0]),
      Uint8List.fromList([255]),
      Uint8List(65537),
    ]) {
      await expectLater(
        adapter.executeDAGBusiness(rb.endpoint, 'putDAGVariable', fields, bad),
        throwsA(isA<GatewayFailure>()),
      );
      expect(bad.every((b) => b == 0), true);
    }
    await expectLater(
      adapter.executeDAGBusiness(rb.endpoint, 'retryDAGWrite', {
        'requestId': 'write-original',
        'environmentId': 'env-fixture',
      }, Uint8List(0)),
      throwsA(isA<GatewayFailure>()),
    );
    expect(calls, 1);
  });
}
