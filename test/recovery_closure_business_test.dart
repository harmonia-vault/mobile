import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/native/native_dag_recovery_adapter.dart';
import 'package:harmonia_mobile/recovery/recovery_gateway.dart';
import 'package:harmonia_mobile/recovery/recovery_presentation.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'recovery_business_test.dart' as base;

// 仅合成 Dart 业务证据；不代替 Go、SDK、HTTP 或真实系统认证。
Map<String, Object?> resolution({String state = 'pending'}) => {
  'version': 1,
  'profile': 'recovery-operation-closure-v1',
  'operationId': 'transition-original',
  'targetHash': 'e' * 64,
  'observation': state == 'pending'
      ? 'unknown'
      : state == 'closed'
      ? 'closed'
      : 'accepted',
  'localState': state,
  'confirmation': state == 'pending'
      ? 'none'
      : state == 'closed'
      ? 'native-confirmed'
      : 'original-history-confirmed',
  'sequence': state == 'pending' ? '0' : '15',
  'rotationRequired': true,
  'trustedDevice': false,
};

class ClosureFixture extends base.DAGPortFixture {
  ClosureFixture() {
    deviceExists = true;
  }
  Map<String, Object?> saved = resolution();
  Map<String, Object?>? discovered;
  String answer = 'closed';
  bool loseClose = false;
  Completer<Map<String, Object?>>? closing;
  @override
  Future<Map<String, Object?>> executeDAGRecovery(
    String endpoint,
    String op,
    Map<String, String> fields,
    Uint8List code,
  ) async {
    if (op == 'dagRecoveryResolutionDiscovery') {
      dagCalls.add((op, Map.of(fields)));
      final state = e['state'] != 'none' || prep['state'] != 'none'
          ? 'unsupported'
          : saved['localState'] == 'closed'
          ? 'closed'
          : p['state'] != 'none'
          ? 'supported-original'
          : 'none';
      return base.envelope(
        op,
        discovered ??
            {
              'version': 1,
              'profile': 'recovery-operation-closure-v1',
              'state': state,
              'operationId': {'closed', 'supported-original'}.contains(state)
                  ? 'transition-original'
                  : '',
              'targetHash': {'closed', 'supported-original'}.contains(state)
                  ? 'e' * 64
                  : '',
              'trustedDevice': false,
            },
      );
    }
    if (!{
      'dagRecoveryResolutionInfo',
      'queryDAGRecoveryResolution',
      'closeDAGRecoveryOriginal',
      'openDAGRecoveryAfterClosure',
    }.contains(op)) {
      return super.executeDAGRecovery(endpoint, op, fields, code);
    }
    dagCalls.add((op, Map.of(fields)));
    lastBytes = code;
    if (op == 'dagRecoveryResolutionInfo') return base.envelope(op, saved);
    if (op == 'openDAGRecoveryAfterClosure') {
      return base.envelope(op, base.owner());
    }
    if (closing != null && op == 'closeDAGRecoveryOriginal') {
      return closing!.future;
    }
    if (loseClose && op == 'closeDAGRecoveryOriginal') {
      loseClose = false;
      throw const GatewayFailure('合成：服务器回应或本机保存未确认');
    }
    saved = resolution(state: answer);
    if (answer == 'closed') p = base.pending();
    return base.envelope(op, saved);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('closure exact DTO拒绝伪closed、伪trusted、额外secret、非规范序号和空目标', () {
    for (final state in ['pending', 'closed', 'accepted-original-confirmed']) {
      expect(
        decodeDAGRecovery(
          'dagRecoveryResolutionInfo',
          base.envelope('dagRecoveryResolutionInfo', resolution(state: state)),
        ).payload,
        isA<RecoveryResolution>(),
      );
    }
    for (final patch in <Map<String, Object?>>[
      {'sequence': '0'},
      {'sequence': 15},
      {'sequence': '015'},
      {'operationId': ''},
      {'targetHash': ''},
      {'trustedDevice': true},
      {'confirmation': 'none'},
      {'rotationRequired': false},
      {'secret': 'synthetic'},
      {'observation': 'accepted'},
    ]) {
      expect(
        () => decodeDAGRecovery(
          'closeDAGRecoveryOriginal',
          base.envelope('closeDAGRecoveryOriginal', {
            ...resolution(state: 'closed'),
            ...patch,
          }),
        ),
        throwsA(isA<GatewayFailure>()),
      );
    }
    expect(
      () => decodeDAGRecovery(
        'closeDAGRecoveryOriginal',
        base.envelope(
          'closeDAGRecoveryOriginal',
          resolution(),
          soft: 'ORIGINAL_RETRY_REQUIRED',
        ),
      ),
      throwsA(isA<GatewayFailure>()),
    );
  });

  test('intent和recovered登记均不开放closure，未确认破坏操作零调用并清码', () async {
    for (final recovered in [false, true]) {
      final fixture = ClosureFixture();
      if (recovered) {
        fixture.e = base.enrolled(exists: true);
      } else {
        fixture.prep = base.preparation(exists: true);
      }
      final (c, _, f) = await base.setup(fixture: fixture);
      addTearDown(c.dispose);
      await c.inspectRecovery();
      expect(c.recovery.allows(RecoveryAction.closeOriginal), false);
      final bytes = base.code();
      await c.closeRecoveryOriginal(bytes, destructiveConfirmed: true);
      expect(bytes, everyElement(0));
      expect(
        f.dagCalls.where(
          (x) =>
              x.$1 == 'dagRecoveryResolutionInfo' ||
              x.$1 == 'queryDAGRecoveryResolution' ||
              x.$1 == 'closeDAGRecoveryOriginal',
        ),
        isEmpty,
      );
    }
    final fixture = ClosureFixture()..p = base.pending(exists: true);
    final (c, _, f) = await base.setup(fixture: fixture);
    addTearDown(c.dispose);
    await c.inspectRecovery();
    final before = f.dagCalls.length, bytes = base.code();
    await c.closeRecoveryOriginal(bytes, destructiveConfirmed: false);
    expect(f.dagCalls.length, before);
    expect(bytes, everyElement(0));
    expect(c.recovery.operationId, 'transition-original');
  });

  test('回应未知保同ID/target，新的controller同原目标查询closed后才显式重开', () async {
    final fixture = ClosureFixture()
      ..p = base.pending(exists: true)
      ..loseClose = true;
    final (first, _, f) = await base.setup(fixture: fixture);
    await first.inspectRecovery();
    final bytes = base.code();
    await first.closeRecoveryOriginal(bytes, destructiveConfirmed: true);
    expect(bytes, everyElement(0));
    expect(first.recovery.operationId, 'transition-original');
    expect(first.recovery.allows(RecoveryAction.restartAfterClosure), false);
    first.dispose();
    final (c, _, _) = await base.setup(fixture: fixture);
    addTearDown(c.dispose);
    await c.inspectRecovery();
    await c.queryRecoveryClosure(base.code());
    expect(c.recovery.stage, RecoveryStage.closed);
    expect(c.recovery.trustedDevice, false);
    expect(c.recovery.allows(RecoveryAction.open), false);
    expect(c.recovery.allows(RecoveryAction.restartAfterClosure), true);
    final requests = f.dagCalls.where(
      (x) => {
        'closeDAGRecoveryOriginal',
        'queryDAGRecoveryResolution',
      }.contains(x.$1),
    );
    expect(requests.length, 2);
    for (final request in requests) {
      expect(request.$2, {
        'operationId': 'transition-original',
        'targetHash': 'e' * 64,
      });
      expect(request.$2['targetHash'], isNot('b' * 64));
    }
    await c.restartRecoveryAfterClosure(base.code());
    expect(c.recovery.stage, RecoveryStage.restricted);
    expect(c.recovery.ownerAvailable, true);
    expect(c.recovery.trustedDevice, false);
    expect(c.recovery.allows(RecoveryAction.prepareCode), true);
    expect(
      f.dagCalls.where((x) => x.$1 == 'beginDAGRecoveryTransition'),
      isEmpty,
    );
  });

  test('pending与accepted均不能当closed重开，accepted不授本机信任', () async {
    for (final answer in ['pending', 'accepted-original-confirmed']) {
      final fixture = ClosureFixture()
        ..p = base.pending(exists: true)
        ..answer = answer;
      final (c, _, _) = await base.setup(fixture: fixture);
      addTearDown(c.dispose);
      await c.inspectRecovery();
      await c.queryRecoveryClosure(base.code());
      expect(c.recovery.allows(RecoveryAction.restartAfterClosure), false);
      expect(c.recovery.allows(RecoveryAction.open), false);
      expect(c.recovery.trustedDevice, false);
      expect(
        c.recovery.stage,
        answer == 'pending'
            ? RecoveryStage.transitionPending
            : RecoveryStage.transitionConfirmed,
      );
      if (answer != 'pending') {
        expect(c.recovery.allows(RecoveryAction.closeOriginal), false);
      }
    }
  });

  test('Info保守unknown不覆盖已验原操作的接受序号与完成阶段', () async {
    final fixture = ClosureFixture()
      ..p = base.pending(exists: true, applied: true);
    final (c, _, _) = await base.setup(fixture: fixture);
    addTearDown(c.dispose);
    await c.inspectRecovery();
    expect(c.recovery.stage, RecoveryStage.transitionConfirmed);
    expect(c.recovery.acceptedSequence, '11');
    expect(c.recovery.allows(RecoveryAction.closeOriginal), false);
    expect(c.recovery.trustedDevice, false);
  });

  test('本机取消先退役晚到closed，不复活owner或开放重开', () async {
    final fixture = ClosureFixture()
      ..p = base.pending(exists: true)
      ..closing = Completer();
    final (c, _, f) = await base.setup(fixture: fixture);
    addTearDown(c.dispose);
    await c.inspectRecovery();
    final bytes = base.code();
    final request = c.closeRecoveryOriginal(bytes, destructiveConfirmed: true);
    for (
      var n = 0;
      n < 100 && !f.dagCalls.any((x) => x.$1 == 'closeDAGRecoveryOriginal');
      n++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(f.dagCalls.any((x) => x.$1 == 'closeDAGRecoveryOriginal'), true);
    await c.cancelRecoveryLocally();
    fixture.closing!.complete(
      base.envelope('closeDAGRecoveryOriginal', resolution(state: 'closed')),
    );
    await request;
    expect(bytes, everyElement(0));
    expect(c.recovery.stage, RecoveryStage.interrupted);
    expect(c.recovery.ownerAvailable, false);
    expect(c.recovery.allows(RecoveryAction.restartAfterClosure), false);
    expect(c.recovery.trustedDevice, false);
  });

  test('closure结果身份或终态回退拒绝，未验收cap保持关闭', () async {
    final fixture = ClosureFixture()..p = base.pending(exists: true);
    final (c, g, _) = await base.setup(fixture: fixture);
    addTearDown(c.dispose);
    await c.inspectRecovery();
    await c.queryRecoveryClosure(base.code());
    fixture.saved = resolution();
    await c.queryRecoveryClosure(base.code());
    expect(c.recovery.stage, RecoveryStage.interrupted);
    expect(c.recovery.allows(RecoveryAction.restartAfterClosure), false);
    await expectLater(
      g.executeRecovery('queryDAGRecoveryResolution', {
        'operationId': 'different-original',
        'targetHash': 'e' * 64,
      }, base.code()),
      throwsA(isA<GatewayFailure>()),
    );
    final (disabled, _, _) = await base.setup(
      fixture: ClosureFixture()..p = base.pending(exists: true),
      evidence: dagRecoveryFields.keys
          .where(
            (x) =>
                !x.contains('Resolution') &&
                x != 'closeDAGRecoveryOriginal' &&
                x != 'openDAGRecoveryAfterClosure',
          )
          .toSet(),
    );
    addTearDown(disabled.dispose);
    await disabled.inspectRecovery();
    expect(disabled.recovery.allows(RecoveryAction.closeOriginal), false);
  });

  test('真正冷closed先成功发现再核同目标，none不猜closed且错误不开放重开', () async {
    final fixture = ClosureFixture()..saved = resolution(state: 'closed');
    final (c, _, f) = await base.setup(fixture: fixture);
    addTearDown(c.dispose);
    await c.inspectRecovery();
    expect(c.recovery.stage, RecoveryStage.closed);
    expect(c.recovery.allows(RecoveryAction.restartAfterClosure), true);
    expect(f.dagCalls.map((x) => x.$1), [
      'dagRecoveryResolutionDiscovery',
      'dagRecoveryResolutionInfo',
    ]);
    expect(c.recovery.trustedDevice, false);
    fixture.saved = {...resolution(state: 'closed'), 'targetHash': 'f' * 64};
    await c.inspectRecovery();
    expect(c.recovery.stage, RecoveryStage.interrupted);
    expect(c.recovery.allows(RecoveryAction.restartAfterClosure), false);
    final (fresh, _, freshPort) = await base.setup(fixture: ClosureFixture());
    addTearDown(fresh.dispose);
    await fresh.inspectRecovery();
    expect(fresh.recovery.allows(RecoveryAction.open), true);
    expect(fresh.recovery.allows(RecoveryAction.restartAfterClosure), false);
    expect(
      freshPort.dagCalls.where((x) => x.$1 == 'dagRecoveryResolutionInfo'),
      isEmpty,
    );
    final empty = {
      'version': 1,
      'profile': 'recovery-operation-closure-v1',
      'state': 'none',
      'operationId': '',
      'targetHash': '',
      'trustedDevice': false,
    };
    for (final patch in <Map<String, Object?>>[
      {'state': 'closed'},
      {'targetHash': 'e' * 64},
      {'trustedDevice': true},
      {'state': 'future'},
      {'secret': 'synthetic'},
    ]) {
      expect(
        () => decodeDAGRecovery(
          'dagRecoveryResolutionDiscovery',
          base.envelope('dagRecoveryResolutionDiscovery', {...empty, ...patch}),
        ),
        throwsA(isA<GatewayFailure>()),
      );
    }
  });

  test('独立DAG profile不借ordinary广告，取消单独编译cap且getter零参数', () async {
    final fixture = ClosureFixture()..nativeCancel = false;
    final (c, g, _) = await base.setup(fixture: fixture);
    addTearDown(c.dispose);
    expect(g.recoveryCapabilities, contains('queryDAGRecoveryResolution'));
    expect(g.runtimeOperations, isNot(contains('queryDAGRecoveryResolution')));
    expect(g.recoveryCapabilities, isNot(contains('cancelDAGRecoveryOwner')));
    final profile = await fixture.dagWorkflowProfile();
    for (final patch in <Map<String, Object?>>[
      {'profile': 'legacy'},
      {'realVaultReady': true},
      {'dispatch': 'executeWorkflow'},
      {
        'operations': ['cancelDAGRecoveryOwner'],
      },
      {
        'operations': ['futureOp'],
      },
      {
        'operations': [
          'dagRecoveryResolutionInfo',
          'dagRecoveryResolutionInfo',
        ],
      },
      {'secret': 'synthetic'},
    ]) {
      expect(
        () => decodeDAGWorkflowProfile({...profile, ...patch}),
        throwsA(isA<GatewayFailure>()),
      );
    }
    const channel = MethodChannel('org.harmoniavault/native/v1');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'dagWorkflowProfile');
      expect(call.arguments, isNull);
      return jsonEncode(profile);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(
      decodeDAGWorkflowProfile(
        await const NativeDAGRecoveryAdapter().dagWorkflowProfile(),
      ),
      contains('dagRecoveryResolutionDiscovery'),
    );
  });

  test('closure MethodChannel只发严格JSON和独立当前码buffer，finally清码', () async {
    const channel = MethodChannel('org.harmoniavault/native/v1');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'executeDAGRecovery');
      final args = call.arguments as Map;
      expect(args.keys.toSet(), {'command', 'completeCode'});
      final command = jsonDecode(args['command'] as String) as Map;
      expect(command, {
        'version': 1,
        'endpoint': base.endpoint,
        'operation': 'closeDAGRecoveryOriginal',
        'operationId': 'transition-original',
        'targetHash': 'e' * 64,
      });
      expect((args['completeCode'] as Uint8List).any((x) => x != 0), true);
      return jsonEncode(
        base.envelope('closeDAGRecoveryOriginal', resolution(state: 'closed')),
      );
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final bytes = base.code();
    await const NativeDAGRecoveryAdapter().executeDAGRecovery(
      base.endpoint,
      'closeDAGRecoveryOriginal',
      {'operationId': 'transition-original', 'targetHash': 'e' * 64},
      bytes,
    );
    expect(bytes, everyElement(0));
  });
}
