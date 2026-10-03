import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'navigation_state_test.dart' show FixtureGateway;

// 纯业务异步顺序回归，不模拟真实Go/Keystore授权，不构建widget。
class DeferredInitialization extends FixtureGateway
    implements InitializationGateway {
  final completed = Completer<VaultSession>();
  final restored = Completer<VaultSession>();
  @override
  Set<String> get capabilities => {
    ...super.capabilities,
    'beginInitialization',
    'completeInitialization',
  };
  @override
  Future<String> beginInitialization(
    String email,
    String password,
    String name,
  ) async => 'synthetic-full-code';
  @override
  Future<VaultSession> completeInitialization(String code) => completed.future;
  @override
  Future<VaultSession> restoreSession() => restored.future;
  @override
  Future<String> queryInitialization() async => 'pending';
}

Future<(VaultController, DeferredInitialization)> prepared() async {
  final g = DeferredInitialization();
  final c = VaultController(gateway: g);
  await c.connectServer('https://fixture.example.invalid');
  await c.signIn('fixture@synthetic.invalid', 'synthetic-only');
  await c.beginInitialization(
    'fixture@synthetic.invalid',
    'synthetic-only',
    '合成环境',
  );
  return (c, g);
}

void main() {
  test('native完成先于resumed：不后台Pull，真实resumed后同epoch继续', () async {
    final (c, g) = await prepared();
    var done = false;
    final operation = c
        .completeInitialization('synthetic-full-code')
        .then((_) => done = true);
    c.onLifecycleState(AppLifecycleState.inactive);
    g.completed.complete(g.result);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(g.reads, 0);
    expect(done, isFalse);
    expect(c.privacyObscured, isTrue);
    c.onLifecycleState(AppLifecycleState.resumed);
    await operation;
    expect(g.reads, 1);
    expect(c.error, isNull);
    expect(c.canEnterVault, isTrue);
    c.dispose();
  });
  test('cold restore也须实际resumed后读取，不能静默跳过Pull', () async {
    final g = DeferredInitialization();
    final c = VaultController(gateway: g);
    var done = false;
    final operation = c.unlockSavedDevice().then((_) => done = true);
    c.onLifecycleState(AppLifecycleState.inactive);
    g.restored.complete(g.result);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(g.reads, 0);
    expect(done, isFalse);
    c.onLifecycleState(AppLifecycleState.resumed);
    await operation;
    expect(g.reads, 1);
    c.dispose();
  });
  for (final state in [AppLifecycleState.paused, AppLifecycleState.hidden]) {
    test('native完成后实际${state.name}：停止原Pull，resumed不复活', () async {
      final (c, g) = await prepared();
      final operation = c.completeInitialization('synthetic-full-code');
      c.onLifecycleState(AppLifecycleState.inactive);
      g.completed.complete(g.result);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      c.onLifecycleState(state);
      await operation;
      c.onLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(g.reads, 0);
      expect(c.canEnterVault, isFalse);
      c.dispose();
    });
  }
  test('等待resumed时logout/服务器epoch更换：旧Pull永不复活', () async {
    final (c, g) = await prepared();
    final operation = c.completeInitialization('synthetic-full-code');
    c.onLifecycleState(AppLifecycleState.inactive);
    g.completed.complete(g.result);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await c.logout();
    c.onLifecycleState(AppLifecycleState.resumed);
    expect(c.switchServer(), isTrue);
    await c.connectServer('https://other.example.invalid');
    await operation;
    expect(g.reads, 0);
    expect(c.sessionStage, SessionStage.signedOut);
    expect(c.endpoint, 'https://other.example.invalid');
    c.dispose();
  });
  test('等待resumed时dispose：原请求有界结束且无Pull', () async {
    final (c, g) = await prepared();
    final operation = c.completeInitialization('synthetic-full-code');
    c.onLifecycleState(AppLifecycleState.inactive);
    g.completed.complete(g.result);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    c.dispose();
    await operation;
    expect(g.reads, 0);
  });
  test('inactive不恢复：五秒有界终止，之后resumed也不重放', () async {
    final (c, g) = await prepared();
    final operation = c.completeInitialization('synthetic-full-code');
    c.onLifecycleState(AppLifecycleState.inactive);
    g.completed.complete(g.result);
    await operation;
    c.onLifecycleState(AppLifecycleState.resumed);
    expect(g.reads, 0);
    expect(c.canEnterVault, isFalse);
    expect(c.busy, isFalse);
    c.dispose();
  });
  test('最后Pull结果先于resumed：遮罩时不显示，resumed后同epoch应用', () async {
    final (c, g) = await prepared();
    g.delayedPull = Completer<VaultSnapshot>();
    var done = false;
    final operation = c
        .completeInitialization('synthetic-full-code')
        .then((_) => done = true);
    g.completed.complete(g.result);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(g.reads, 1);
    c.onLifecycleState(AppLifecycleState.inactive);
    g.delayedPull!.complete(
      VaultSnapshot(
        checkpoint: 9,
        environments: [
          VaultEnvironment(
            id: 'fixture-env',
            name: '合成环境',
            role: AccessRole.admin,
            variables: const [],
          ),
        ],
        devices: const [],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(done, isFalse);
    expect(c.checkpoint, 0);
    expect(c.environments, isEmpty);
    c.onLifecycleState(AppLifecycleState.resumed);
    await operation;
    expect(c.checkpoint, 9);
    expect(c.environments.length, 1);
    expect(c.error, isNull);
    c.dispose();
  });
  test('最后Pull结果在paused返回：恢复前台后也不应用旧结果', () async {
    final (c, g) = await prepared();
    g.delayedPull = Completer<VaultSnapshot>();
    final operation = c.completeInitialization('synthetic-full-code');
    g.completed.complete(g.result);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(g.reads, 1);
    c.onLifecycleState(AppLifecycleState.paused);
    g.delayedPull!.complete(
      VaultSnapshot(checkpoint: 9, environments: const [], devices: const []),
    );
    await operation;
    c.onLifecycleState(AppLifecycleState.resumed);
    expect(c.checkpoint, 0);
    expect(c.canEnterVault, isFalse);
    c.dispose();
  });
  test('最后Pull结果等待resumed时logout：旧返回不复活会话', () async {
    final (c, g) = await prepared();
    g.delayedPull = Completer<VaultSnapshot>();
    final operation = c.completeInitialization('synthetic-full-code');
    g.completed.complete(g.result);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(g.reads, 1);
    c.onLifecycleState(AppLifecycleState.inactive);
    g.delayedPull!.complete(
      VaultSnapshot(checkpoint: 9, environments: const [], devices: const []),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await c.logout();
    c.onLifecycleState(AppLifecycleState.resumed);
    await operation;
    expect(c.sessionStage, SessionStage.signedOut);
    expect(c.checkpoint, 0);
    expect(c.canEnterVault, isFalse);
    c.dispose();
  });
}
