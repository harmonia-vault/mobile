import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/vault_controller.dart';

/// 全部为公开合成状态来源，不模拟真实系统认证或服务端授权。
class FixtureGateway implements SessionVaultGateway, InstanceConnectionGateway {
  @override
  bool get synthetic => false;
  @override
  Set<String> capabilities = {
    'restoreSession',
    'loginAccount',
    'authorizationRequests',
  };
  VaultSession result = const VaultSession(
    SessionStage.trusted,
    accountId: 'account-fixture',
    accountGeneration: '1',
  );
  AccountAuthentication authentication = const AccountAuthentication(
    authenticated: true,
    trustedDevice: false,
  );
  List<AuthorizationRequest> requests = [];
  Completer<VaultSnapshot>? delayedPull;
  int reads = 0, logouts = 0, approvals = 0;
  @override
  Future<void> initialize(String endpoint) async {}
  @override
  Future<InstanceDescriptor> inspectInstance(String endpoint) async =>
      const InstanceDescriptor(
        initialRegistrationAvailable: false,
        allowRegistration: true,
        emailVerificationRequired: true,
      );

  @override
  Future<AccountAuthentication> loginAccount(
    String email,
    String password,
  ) async => authentication;
  @override
  Future<void> registerAccount(String email, String password) async {}
  @override
  Future<VaultSession> restoreSession() async => result;
  @override
  Future<VaultSnapshot> pull() async {
    reads++;
    return delayedPull?.future ??
        Future.value(
          VaultSnapshot(
            checkpoint: 4,
            environments: [
              VaultEnvironment(
                id: 'fixture-env',
                name: '合成环境',
                role: AccessRole.admin,
                variables: const [
                  VaultVariable(name: 'DEMO_VALUE', value: 'synthetic-only'),
                ],
              ),
            ],
            devices: const [
              VaultDevice(
                id: 'fixture-device',
                name: '合成设备',
                platform: 'fixture',
                accessSummary: '合成权限',
                expiresLabel: '合成期限',
                current: true,
              ),
            ],
          ),
        );
  }

  @override
  Future<void> submit(PreviewMutation mutation) async =>
      throw const GatewayFailure('fixture无写入');
  @override
  Future<void> logout() async {
    logouts++;
  }

  @override
  Future<List<AuthorizationRequest>> authorizationRequests() async => requests;
  @override
  Future<void> approve(ApprovalDraft draft) async {
    approvals++;
  }

  @override
  Future<void> revoke(String deviceId) async {}
}

void main() {
  test('冷启动没有账号内容，内部导航和深链接不能穿过门槛', () async {
    final gateway = FixtureGateway();
    final c = VaultController(gateway: gateway);
    await c.initialize();
    expect(c.sessionStage, SessionStage.signedOut);
    expect(c.environments, isEmpty);
    expect(c.devices, isEmpty);
    expect(c.checkpoint, 0);
    for (final page in [
      VaultPage.environments,
      VaultPage.devices,
      VaultPage.settings,
      VaultPage.environmentDetail,
      VaultPage.deviceDetail,
      VaultPage.recoveryManagement,
    ]) {
      expect(
        c.navigate(
          page,
          environmentId: 'fixture-env',
          deviceId: 'fixture-device',
        ),
        isFalse,
      );
    }
    expect(
      c.openDeepLink(Uri.parse('harmonia://environment/fixture-env')),
      isFalse,
    );
    expect(gateway.reads, 0);
    c.dispose();
  });

  test('演示构建也需显式开发入口，不能把reload当假登录', () async {
    final c = VaultController(
      gateway: SyntheticPreviewGateway(),
      allowPreview: true,
    );
    await c.reload();
    expect(c.environments, isEmpty);
    expect(c.canEnterVault, isFalse);
    await c.enterPreview();
    expect(c.sessionStage, SessionStage.preview);
    expect(c.environments, isNotEmpty);
    await c.logout();
    expect(c.sessionStage, SessionStage.signedOut);
    expect(c.goBack(), isFalse);
    expect(c.environments, isEmpty);
    c.dispose();
  });

  test('未授权开发开关不能进入合成保险库', () async {
    final c = VaultController(gateway: SyntheticPreviewGateway());
    await c.enterPreview();
    expect(c.previewAvailable, isFalse);
    expect(c.canEnterVault, isFalse);
    expect(c.environments, isEmpty);
    c.dispose();
  });

  test('真实账号登录成功仅到设备授权，不读取保险库', () async {
    final gateway = FixtureGateway();
    final c = VaultController(gateway: gateway);
    await c.connectServer('https://fixture.example.invalid');
    await c.signIn('fixture@example.invalid', 'synthetic-password');
    expect(c.sessionStage, SessionStage.deviceAuthorization);
    expect(c.location.page, VaultPage.authorization);
    expect(c.canEnterVault, isFalse);
    expect(c.navigate(VaultPage.settings), isFalse);
    expect(
      c.openDeepLink(Uri.parse('harmonia://environment/fixture-env')),
      isFalse,
    );
    expect(gateway.reads, 0);
    c.dispose();
  });

  test('login错误声称trusted被拒绝，不能用登录替代设备授权', () async {
    final gateway = FixtureGateway()
      ..authentication = const AccountAuthentication(
        authenticated: true,
        trustedDevice: true,
      );
    final c = VaultController(gateway: gateway);
    await c.connectServer('https://fixture.example.invalid');
    await c.signIn('fixture@example.invalid', 'synthetic-password');
    expect(c.sessionStage, SessionStage.signedOut);
    expect(c.error, isNotNull);
    expect(gateway.reads, 0);
    c.dispose();
  });

  test('受限恢复不因恢复完成或检查点存在进入保险库', () async {
    final gateway = FixtureGateway()
      ..result = const VaultSession(
        SessionStage.restrictedRecovery,
        accountId: 'account-fixture',
        accountGeneration: '1',
      );
    final c = VaultController(gateway: gateway);
    await c.unlockSavedDevice();
    expect(c.restrictedRecovery, isTrue);
    expect(c.location.page, VaultPage.recovery);
    expect(c.canEnterVault, isFalse);
    expect(c.navigate(VaultPage.devices), isFalse);
    expect(gateway.reads, 0);
    c.dispose();
  });

  test('已核验可信状态可恢复；未知或删除的环境不能通过深链接', () async {
    final c = VaultController(gateway: FixtureGateway());
    await c.unlockSavedDevice();
    expect(c.canEnterVault, isTrue);
    expect(
      c.openDeepLink(Uri.parse('harmonia://environment/fixture-env')),
      isTrue,
    );
    expect(c.location.page, VaultPage.environmentDetail);
    expect(
      c.openDeepLink(Uri.parse('harmonia://environment/missing')),
      isFalse,
    );
    expect(c.goBack(), isTrue);
    expect(c.location.page, VaultPage.environments);
    c.dispose();
  });

  test('可信结果缺账号代际拒绝；App重开不沿用Dart登录布尔', () async {
    final gateway = FixtureGateway()
      ..result = const VaultSession(SessionStage.trusted);
    final c = VaultController(gateway: gateway);
    await c.unlockSavedDevice();
    expect(c.canEnterVault, isFalse);
    c.dispose();
    final reopened = VaultController(gateway: FixtureGateway());
    expect(reopened.sessionStage, SessionStage.signedOut);
    expect(reopened.environments, isEmpty);
    reopened.dispose();
  });

  test('退出期间旧异步pull不得重新填回保险库或历史页面', () async {
    final gateway = FixtureGateway();
    final c = VaultController(gateway: gateway);
    await c.unlockSavedDevice();
    c.navigate(VaultPage.environmentDetail, environmentId: 'fixture-env');
    gateway.delayedPull = Completer<VaultSnapshot>();
    final refresh = c.reload();
    await c.logout();
    gateway.delayedPull!.complete(
      VaultSnapshot(checkpoint: 9, environments: const [], devices: const []),
    );
    await refresh;
    expect(c.sessionStage, SessionStage.signedOut);
    expect(c.location.page, VaultPage.entry);
    expect(c.goBack(), isFalse);
    expect(c.checkpoint, 0);
    expect(c.environments, isEmpty);
    c.dispose();
  });

  test('有会话不能原地换服务器；退出后保留地址且关闭旧scope', () async {
    final gateway = FixtureGateway();
    final c = VaultController(gateway: gateway);
    await c.setEndpoint('https://fixture.example.invalid');
    await c.unlockSavedDevice();
    await c.setEndpoint('https://other.example.invalid');
    expect(c.error, isNotNull);
    expect(c.endpoint, 'https://fixture.example.invalid');
    await c.logout();
    expect(c.endpoint, 'https://fixture.example.invalid');
    expect(gateway.logouts, 1);
    await c.setEndpoint('https://other.example.invalid');
    expect(c.error, isNull);
    expect(c.environments, isEmpty);
    c.dispose();
  });

  test('PairID/generation/状态去重，一条active提示，取消不反复弹', () async {
    var now = DateTime.utc(2026, 10, 3);
    final gateway = FixtureGateway();
    final c = VaultController(gateway: gateway, now: () => now);
    await c.unlockSavedDevice();
    AuthorizationRequest request(
      String id,
      int sequence, {
      AuthorizationRequestStatus status = AuthorizationRequestStatus.pending,
      String generation = '1',
    }) => AuthorizationRequest(
      id: id,
      accountId: 'account-fixture',
      accountGeneration: generation,
      deviceName: '合成请求设备',
      platform: 'fixture',
      expiresAt: now.add(const Duration(minutes: 1)),
      sequence: sequence,
      status: status,
    );
    gateway.requests = [
      request('pair-a', 1),
      request('pair-b', 2),
      request('wrong-gen', 3, generation: '2'),
    ];
    await c.refreshAuthorizationRequests();
    expect(c.pendingAuthorizationCount, 2);
    expect(c.takeAuthorizationPrompt()?.id, 'pair-a');
    expect(c.takeAuthorizationPrompt(), isNull);
    c.dismissAuthorizationPrompt();
    expect(c.takeAuthorizationPrompt()?.id, 'pair-b');
    c.dismissAuthorizationPrompt();
    gateway.requests = [request('pair-a', 4), request('pair-b', 5)];
    await c.refreshAuthorizationRequests();
    expect(c.takeAuthorizationPrompt(), isNull);
    expect(gateway.approvals, 0);
    now = now.add(const Duration(minutes: 2));
    c.purgeExpiredAuthorizationRequests();
    expect(c.pendingAuthorizationCount, 0);
    expect(c.takeAuthorizationPrompt(), isNull);
    c.dispose();
  });

  test('撤销或过期请求关闭二级详情；旧事件不会复活请求', () async {
    final now = DateTime.utc(2026, 10, 3);
    final gateway = FixtureGateway();
    final c = VaultController(gateway: gateway, now: () => now);
    await c.unlockSavedDevice();
    AuthorizationRequest r(int seq, AuthorizationRequestStatus status) =>
        AuthorizationRequest(
          id: 'pair-a',
          accountId: 'account-fixture',
          accountGeneration: '1',
          deviceName: '合成',
          platform: 'fixture',
          expiresAt: now.add(const Duration(minutes: 1)),
          sequence: seq,
          status: status,
        );
    gateway.requests = [r(1, AuthorizationRequestStatus.pending)];
    await c.refreshAuthorizationRequests();
    c.selectTab(VaultPage.devices);
    expect(c.navigate(VaultPage.deviceDetail, requestId: 'pair-a'), isTrue);
    gateway.requests = [r(2, AuthorizationRequestStatus.revoked)];
    await c.refreshAuthorizationRequests();
    expect(c.pendingAuthorizationCount, 0);
    expect(c.location.page, VaultPage.devices);
    gateway.requests = [r(1, AuthorizationRequestStatus.pending)];
    await c.refreshAuthorizationRequests();
    expect(c.pendingAuthorizationCount, 0);
    expect(c.takeAuthorizationPrompt(), isNull);
    c.dispose();
  });

  test('后台不检查或弹通知；没有真实来源cap不能产生真实badge', () async {
    final now = DateTime.utc(2026, 10, 3);
    final gateway = FixtureGateway();
    final c = VaultController(gateway: gateway, now: () => now);
    await c.unlockSavedDevice();
    gateway.requests = [
      AuthorizationRequest(
        id: 'pair-a',
        accountId: 'account-fixture',
        accountGeneration: '1',
        deviceName: '合成',
        platform: 'fixture',
        expiresAt: now.add(const Duration(minutes: 1)),
        sequence: 1,
      ),
    ];
    c.setForeground(false);
    await c.refreshAuthorizationRequests();
    expect(c.pendingAuthorizationCount, 0);
    expect(c.takeAuthorizationPrompt(), isNull);
    c.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(c.takeAuthorizationPrompt()?.id, 'pair-a');
    c.dismissAuthorizationPrompt();
    gateway.capabilities.remove('authorizationRequests');
    expect(c.authorizationRequestsAvailable, isFalse);
    expect(c.takeAuthorizationPrompt(), isNull);
    c.dispose();
  });
}
