import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/vault_controller.dart';

void main() {
  test('默认路径拒绝真实读取、登录、批准、撤销和恢复', () async {
    final c = VaultController(gateway: FailClosedGateway());
    await c.reload();
    expect(c.phase, ConnectionPhase.blocked);
    expect(c.environments, isEmpty);
    expect(c.checkpoint, 0);
    for (final action in <Future<void> Function()>[
      () => c.signIn('demo@example.invalid', 'synthetic-not-a-password'),
      () => c.approveDevice(
        ApprovalDraft(code: '123456', roles: const {}, lifetime: null),
      ),
      () => c.revokeDevice('demo-device'),
      c.beginRecovery,
      () => c.rotateRecovery('synthetic-not-a-recovery-code'),
      c.queryRecoveryStatus,
      () => c.createEnvironment('示例'),
    ]) {
      await action();
      expect(c.error, isNotNull);
      expect(c.checkpoint, 0);
      expect(c.environments, isEmpty);
    }
    c.dispose();
  });

  test('服务地址只接受无凭据的 HTTPS，拒绝时保留旧地址', () async {
    final c = VaultController(gateway: FailClosedGateway());
    for (final address in [
      'http://example.invalid',
      'https://user:pass@example.invalid',
      'https://example.invalid?token=synthetic',
      'https://example.invalid#fragment',
      'https://',
      'not-a-url',
    ]) {
      await c.setEndpoint(address);
      expect(c.error, isNotNull);
      expect(c.endpoint, 'https://vault.example.invalid');
    }
    await c.setEndpoint('https://other.example.invalid:8443/api');
    expect(c.error, isNull);
    expect(c.endpoint, 'https://other.example.invalid:8443/api');
    expect(c.phase, ConnectionPhase.blocked);
    c.dispose();
  });

  test('合成预览 CRUD 经接受后拉取生效，删除不改其他环境', () async {
    final c = VaultController(gateway: SyntheticPreviewGateway());
    await c.reload();
    expect(c.phase, ConnectionPhase.preview);
    final initial = c.checkpoint;
    await c.createEnvironment('测试环境');
    final created = c.environments.last;
    expect(c.checkpoint, initial + 1);
    await c.renameEnvironment(created.id, '已改名');
    await c.setVariable(created.id, 'DEMO_VALUE', 'synthetic-value');
    expect(c.environments.last.name, '已改名');
    expect(c.environments.last.variables.single.value, 'synthetic-value');
    await c.deleteVariable(created.id, 'DEMO_VALUE');
    expect(c.environments.last.variables, isEmpty);
    await c.deleteEnvironment(created.id);
    expect(
      c.environments.map((e) => e.id),
      containsAll(['demo-development', 'demo-review']),
    );
    expect(c.environments.length, 2);
    expect(c.checkpoint, initial + 5);
    c.dispose();
  });

  test('只读角色不能用控制层绕过界面权限', () async {
    final c = VaultController(gateway: SyntheticPreviewGateway());
    await c.reload();
    final initial = c.checkpoint;
    await c.setVariable('demo-review', 'LOG_LEVEL', 'debug');
    expect(c.error, contains('角色'));
    await c.renameEnvironment('demo-review', '越权');
    expect(c.error, contains('角色'));
    await c.deleteEnvironment('demo-review');
    expect(c.error, contains('角色'));
    expect(c.checkpoint, initial);
    expect(c.environments.last.variables.single.value, 'info');
    c.dispose();
  });

  test('变量校验拒绝非法名称和空字符，快照不变', () async {
    final c = VaultController(gateway: SyntheticPreviewGateway());
    await c.reload();
    final initial = c.checkpoint;
    await c.setVariable('demo-development', 'BAD-NAME', 'synthetic');
    expect(c.error, isNotNull);
    await c.setVariable('demo-development', 'GOOD_NAME', 'synthetic\u0000');
    expect(c.error, isNotNull);
    await c.createEnvironment('   ');
    expect(c.error, isNotNull);
    expect(c.checkpoint, initial);
    c.dispose();
  });

  test('接受后拉取失败不乐观修改快照，重查才应用', () async {
    final gateway = RecordingGateway();
    final c = VaultController(gateway: gateway);
    await c.reload();
    gateway.failPull = true;
    await c.createEnvironment('仅在服务器接受');
    expect(gateway.accepted, 1);
    expect(c.error, isNotNull);
    expect(c.checkpoint, 1);
    expect(c.environments, isEmpty);
    gateway.failPull = false;
    await c.reload();
    expect(c.checkpoint, 2);
    expect(c.environments.single.name, '仅在服务器接受');
    c.dispose();
  });

  test('检查点回退被拒绝', () async {
    final gateway = RecordingGateway();
    final c = VaultController(gateway: gateway);
    await c.reload();
    await c.createEnvironment('新环境');
    gateway.sequence = 0;
    await c.reload();
    expect(c.error, contains('检查点倒退'));
    expect(c.checkpoint, 2);
    expect(c.environments.single.name, '新环境');
    c.dispose();
  });

  test('重复点击在请求运行时不会额外提交', () async {
    final gateway = RecordingGateway();
    final c = VaultController(gateway: gateway);
    await c.reload();
    gateway.acceptance = Completer<void>();
    final first = c.createEnvironment('第一个');
    expect(c.busy, isTrue);
    await c.createEnvironment('重复点击');
    expect(gateway.accepted, 1);
    gateway.acceptance!.complete();
    await first;
    expect(c.environments.single.name, '第一个');
    c.dispose();
  });

  test('预览也不模拟可信授权或恢复成功', () async {
    final gateway = RecordingGateway();
    final c = VaultController(gateway: gateway);
    await c.approveDevice(
      ApprovalDraft(code: '123456', roles: const {}, lifetime: null),
    );
    await c.signIn('demo@example.invalid', 'synthetic-not-a-password');
    await c.rotateRecovery('synthetic-code');
    expect(gateway.accepted, 0);
    expect(gateway.pulls, 0);
    expect(c.error, isNotNull);
    c.dispose();
  });
}

class RecordingGateway implements VaultGateway {
  @override
  bool get synthetic => true;
  int sequence = 1, accepted = 0, pulls = 0;
  bool failPull = false;
  Completer<void>? acceptance;
  final environments = <VaultEnvironment>[];
  @override
  Future<VaultSnapshot> pull() async {
    pulls++;
    if (failPull) throw const GatewayFailure('合成网络中断，需查询');
    return VaultSnapshot(
      checkpoint: sequence,
      environments: environments,
      devices: const [],
    );
  }

  @override
  Future<void> submit(PreviewMutation mutation) async {
    accepted++;
    if (acceptance != null) await acceptance!.future;
    sequence++;
    environments.add(
      VaultEnvironment(
        id: 'synthetic-$sequence',
        name: mutation.name!,
        role: AccessRole.admin,
        variables: const [],
      ),
    );
  }
}
