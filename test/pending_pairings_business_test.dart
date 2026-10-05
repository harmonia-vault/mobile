import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/native/native_pending_pairings_adapter.dart';
import 'package:harmonia_mobile/native/native_vault_gateway.dart';
import 'package:harmonia_mobile/pairing/pending_pairing_presentation.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'native_gateway_mapping_test.dart' show PortFixture;

// 合成Dart边界证据；Go内部fresh Boot/Pull由独立Go合同/真实链验证。
const endpoint = 'https://fixture.example.invalid';
final start = DateTime.utc(2030, 1, 1);
Map<String, Object?> row({
  String id = 'pair-original',
  String state = 'pending',
  DateTime? expiry,
}) => {
  'idempotencyKey': id,
  'initiatorDeviceId': 'device-initiator',
  'state': state,
  'expiresAt':
      ((expiry ?? start.add(const Duration(minutes: 5)))
                  .millisecondsSinceEpoch ~/
              1000)
          .toString(),
};
Map<String, Object?> snapshot({
  String version = '5',
  List<Map<String, Object?>>? rows,
}) => {
  'accountId': 'account-fixture',
  'accountGeneration': '1',
  'approverDeviceId': 'a' * 64,
  'certificateVersion': version,
  'capabilities': ['issuer-recovery-dag-v1'],
  'requests': rows ?? [row()],
  'authoritativeForApproval': false,
};
Map<String, Object?> envelope(String operation, Map<String, Object?> data) => {
  'version': 1,
  'operation': operation,
  'ok': true,
  'data': data,
};

class PendingPort extends PortFixture implements NativePendingPairingsPort {
  bool compiled5 = true;
  Map<String, Object?> data = snapshot();
  final reads = <String>[];
  Completer<Map<String, Object?>>? delayed;
  String? failure;
  @override
  Future<Map<String, Object?>> capabilities() async => {
    ...await super.capabilities(),
    'nativePendingPairingRequestsV5': compiled5,
  };
  @override
  Future<Map<String, Object?>> executePendingPairings(
    String ep,
    String op,
  ) async {
    expect(ep, endpoint);
    reads.add(op);
    if (failure != null) {
      throw PlatformException(
        code: failure!,
        message: 'synthetic private Go text',
      );
    }
    return delayed?.future ?? envelope(op, data);
  }
}

Future<(VaultController, NativeVaultGateway, PendingPort)> setup({
  PendingPort? fixture,
  Set<String>? evidence,
  bool explicitSource = true,
  DateTime Function()? now,
}) async {
  final f = fixture ?? PendingPort();
  final clock = now ?? () => start;
  final g = NativeVaultGateway(
    experimentalOptIn: true,
    port: f,
    verifiedPendingPairingOperations: evidence ?? pendingPairingOperations,
    now: clock,
    inspector: (_) async => const InstanceDescriptor(
      initialRegistrationAvailable: false,
      allowRegistration: false,
      emailVerificationRequired: false,
    ),
  );
  final c = VaultController(gateway: g, now: clock);
  await c.initialize();
  await c.connectServer(endpoint);
  if (explicitSource) {
    final code = await g.beginInitialization(
      'synthetic@example.invalid',
      'synthetic-only',
      'fixture',
    );
    await g.completeInitialization(code);
  }
  await c.unlockSavedDevice();
  return (c, g, f);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('strict V3/V4 snapshot拒绝来源错配、authority、秘密字段、重复ID和非法到期', () {
    for (final version in ['5']) {
      final op = 'pendingPairingRequestsV$version';
      final parsed = decodePendingPairings(
        op,
        envelope(op, snapshot(version: version)),
      );
      expect(parsed.certificateVersion, version);
      expect(parsed.authoritativeForApproval, false);
    }
    const op = 'pendingPairingRequestsV5';
    for (final patch in <Map<String, Object?>>[
      {'certificateVersion': '4'},
      {
        'capabilities': ['issuer-recovery-v1'],
      },
      {'authoritativeForApproval': true},
      {'accountGeneration': 1},
      {'accountGeneration': '01'},
      {
        'requests': [row(), row()],
      },
      {
        'requests': [
          {...row(), 'expiresAt': '0'},
        ],
      },
      {
        'requests': [
          {...row(), 'expiresAt': '18446744073709551615'},
        ],
      },
      {
        'requests': [
          {...row(), 'state': 'trusted'},
        ],
      },
      {'sequence': 1},
      {
        'requests': [
          {...row(), 'name': 'invented'},
        ],
      },
      {'secret': 'synthetic'},
      {'requests': List.generate(65, (i) => row(id: 'pair-$i'))},
    ]) {
      expect(
        () =>
            decodePendingPairings(op, envelope(op, {...snapshot(), ...patch})),
        throwsA(isA<GatewayFailure>()),
      );
    }
  });

  test('独立channel仅command三字段，零code/bearer且错误不返回空快照', () async {
    const channel = MethodChannel('org.harmoniavault/native/v1');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var reject = false, calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      expect(call.method, 'executePendingPairings');
      final args = call.arguments as Map;
      expect(args.keys.toSet(), {'command'});
      final command = jsonDecode(args['command'] as String);
      expect(command, {
        'version': 1,
        'endpoint': endpoint,
        'operation': 'pendingPairingRequestsV5',
      });
      if (reject) throw PlatformException(code: 'AUTH_CANCELLED');
      return jsonEncode(envelope('pendingPairingRequestsV5', snapshot()));
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    const adapter = NativePendingPairingsAdapter();
    final raw = await adapter.executePendingPairings(
      endpoint,
      'pendingPairingRequestsV5',
    );
    expect(
      decodePendingPairings('pendingPairingRequestsV5', raw).requests,
      hasLength(1),
    );
    reject = true;
    await expectLater(
      adapter.executePendingPairings(endpoint, 'pendingPairingRequestsV5'),
      throwsA(isA<PlatformException>()),
    );
    await expectLater(
      adapter.executePendingPairings(endpoint, 'pendingPairingRequestsV3'),
      throwsA(isA<GatewayFailure>()),
    );
    expect(calls, 2);
  });

  test('缺少编译能力或独立证据时不可读取申请', () async {
    for (final mode in ['evidence-empty', 'compiled-missing']) {
      final fixture = PendingPort()..compiled5 = mode != 'compiled-missing';
      final (c, g, f) = await setup(
        fixture: fixture,
        evidence: mode == 'evidence-empty' ? {} : pendingPairingOperations,
        explicitSource: true,
      );
      addTearDown(c.dispose);
      expect(g.pendingPairingsAvailable, false);
      await c.refreshPendingPairings();
      expect(c.pendingPairings.requests, isEmpty);
      expect(f.reads, isEmpty);
    }
  });

  test('冷恢复可信会话可以读取申请，申请列表不能授予权限', () async {
    final (c, g, f) = await setup(explicitSource: false);
    addTearDown(c.dispose);
    expect(g.pendingPairingsAvailable, true);
    await c.refreshPendingPairings();
    expect(c.pendingPairings.requests.single.pairingId, 'pair-original');
    expect(c.pendingPairings.authoritativeForApproval, false);
    expect(f.approvalVersion, 0);
  });

  test('每次刷新独立native读且整快照替换，同ID不叠加/approved不是权限', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    final ordinary = f.calls.length;
    await c.refreshPendingPairings();
    await c.refreshPendingPairings();
    expect(f.reads, ['pendingPairingRequestsV5', 'pendingPairingRequestsV5']);
    expect(f.calls.length, ordinary); // 不用旧execute/缓存view伪装fresh native读取。
    expect(c.pendingPairings.requests.single.pairingId, 'pair-original');
    expect(
      c.pendingPairings.requests.single.initiatorDeviceId,
      'device-initiator',
    );
    expect(c.pendingPairings.authoritativeForApproval, false);
    f.data = snapshot(rows: [row(state: 'approved')]);
    await c.refreshPendingPairings();
    expect(
      c.pendingPairings.requests.single.state,
      PendingPairingState.approved,
    );
    expect(c.pendingPairings.pendingCount, 0);
    expect(f.approvalVersion, 0); // 没有执行批准。
    f.data = snapshot(rows: []);
    await c.refreshPendingPairings();
    expect(c.pendingPairings.requests, isEmpty);
  });

  test('本机到期停止显示，网络失败清旧提示但不假称服务器取消', () async {
    var clock = start;
    final (c, _, f) = await setup(now: () => clock);
    addTearDown(c.dispose);
    await c.refreshPendingPairings();
    expect(c.pendingPairings.pendingCount, 1);
    clock = start.add(const Duration(minutes: 6));
    expect(c.pendingPairings.requests, isEmpty);
    clock = start;
    await c.refreshPendingPairings();
    f.failure = 'NETWORK_FAILED';
    await c.refreshPendingPairings();
    expect(c.pendingPairings.requests, isEmpty);
    expect(c.pendingPairings.error, isNotNull);
    expect(c.pendingPairings.error, isNot(contains('private Go text')));
    expect(c.canEnterVault, true);
  });

  test('scope错配与信任撤销均清提示并停止真实读取', () async {
    for (final mode in ['generation', 'approver', 'trust', 'persistence']) {
      final (c, g, f) = await setup();
      addTearDown(c.dispose);
      await c.refreshPendingPairings();
      if (mode == 'trust' || mode == 'persistence') {
        f.failure = mode == 'trust'
            ? 'TRUST_INVALIDATED'
            : 'LOCAL_PROTECTION_PERSISTENCE';
      } else {
        f.data = {
          ...snapshot(),
          mode == 'generation' ? 'accountGeneration' : 'approverDeviceId':
              mode == 'generation' ? '2' : 'other-device',
        };
      }
      await c.refreshPendingPairings();
      expect(c.pendingPairings.requests, isEmpty);
      expect(c.canEnterVault, false);
      expect(g.pendingPairingsAvailable, false);
      if (mode == 'persistence') {
        await expectLater(g.restoreSession(), throwsA(isA<GatewayFailure>()));
        await expectLater(
          g.loginAccount('synthetic@example.invalid', 'synthetic-only'),
          throwsA(isA<GatewayFailure>()),
        );
        expect(f.calls.where((x) => x.$1 == 'loginAccount'), isEmpty);
        f.failure = null;
        await c.logout(); // 成功清槽才解除cleanup门；仍须以后重新授权。
        expect(c.canEnterVault, false);
        expect(g.protectedDeviceExists, false);
        expect(g.pendingPairingsAvailable, false);
      }
    }
  });

  test('后台与Logout使在途结果退役，不复活前台提示', () async {
    for (final logout in [false, true]) {
      final (c, _, f) = await setup();
      addTearDown(c.dispose);
      f.delayed = Completer();
      final reading = c.refreshPendingPairings();
      for (var i = 0; i < 100 && f.reads.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(f.reads, hasLength(1));
      if (logout) {
        await c.logout();
      } else {
        c.setForeground(false);
      }
      f.delayed!.complete(envelope('pendingPairingRequestsV5', snapshot()));
      await reading;
      expect(c.pendingPairings.requests, isEmpty);
      expect(c.pendingPairings.busy, false);
    }
  });

  test('失去Admin清提示，同账号重新验证后也不复活旧列表', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await c.refreshPendingPairings();
    expect(c.pendingPairings.pendingCount, 1);
    final envs = f.view['environments'] as List;
    final original = Map<String, Object?>.from(envs.single as Map);
    f.view = {
      ...f.view,
      'environments': [
        {...original, 'role': 'RO'},
      ],
    };
    await c.reload();
    expect(c.pendingPairings.requests, isEmpty);
    expect(c.pendingPairings.available, false);
    f.view = {
      ...f.view,
      'environments': [original],
    };
    await c.unlockSavedDevice();
    expect(c.pendingPairings.available, true);
    expect(c.pendingPairings.requests, isEmpty);
    expect(f.reads, hasLength(1));
  });

  test('列表只携原PairID；实际批准仍用短码/显式角色期限并清过时提示', () async {
    final (c, _, f) = await setup();
    addTearDown(c.dispose);
    await c.refreshPendingPairings();
    final id = c.pendingPairings.requests.single.pairingId;
    await c.approveDevice(
      ApprovalDraft(
        pairingId: id,
        code: '12345678',
        roles: {'env-fixture': AccessRole.readOnly},
        lifetime: const Duration(minutes: 15),
      ),
    );
    expect(f.approvalVersion, 5);
    expect(f.pairingId, id);
    expect(c.pendingPairings.requests, isEmpty);
    expect(f.consumedCode, everyElement(0));
  });
}
