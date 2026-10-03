import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'navigation_state_test.dart' show FixtureGateway;

class ConnectionFixture extends FixtureGateway
    implements InstanceConnectionGateway {
  Object response = {
    'product': 'harmonia',
    'status': 'experimental',
    'protocol': {
      'supportedMajors': [1],
      'capabilities': ['registration-policy-v1', 'email-proof-v1'],
    },
    'initialRegistrationAvailable': false,
    'allowRegistration': true,
    'emailVerificationRequired': true,
  };
  int inspections = 0;
  Completer<InstanceDescriptor>? wait;
  @override
  Future<InstanceDescriptor> inspectInstance(String endpoint) async {
    inspections++;
    return wait?.future ?? Future.value(InstanceDescriptor.parse(response));
  }
}

class DeferredCleanupFixture extends ConnectionFixture {
  Completer<void> cleanup = Completer<void>();
  int logins = 0, restores = 0, initializations = 0;
  @override
  Future<void> logout() async {
    logouts++;
    await cleanup.future;
  }

  @override
  Future<void> initialize(String endpoint) async {
    initializations++;
  }

  @override
  Future<AccountAuthentication> loginAccount(
    String email,
    String password,
  ) async {
    logins++;
    return authentication;
  }

  @override
  Future<VaultSession> restoreSession() async {
    restores++;
    return result;
  }
}

class PrivacyFixture extends FixtureGateway implements AppPrivacyGateway {
  AppPrivacyStatus state = const AppPrivacyStatus(
    enabled: true,
    locked: true,
    systemPromptInFlight: false,
  );
  bool cancelled = false;
  int unlocks = 0;
  @override
  AppPrivacyStatus get privacyStatus => state;
  @override
  Future<void> unlockPrivacy() async {
    unlocks++;
    if (cancelled) throw const GatewayFailure('AUTH_CANCELLED：仍锁定，不降级');
    state = const AppPrivacyStatus(
      enabled: true,
      locked: false,
      systemPromptInFlight: false,
    );
  }
}

void main() {
  test('deferred logout关闭所有新intent，重复logout合并；真实清理成功才允许switch', () async {
    final g = DeferredCleanupFixture();
    final c = VaultController(gateway: g);
    await c.connectServer('https://fixture.example.invalid');
    await c.unlockSavedDevice();
    final before = g.inspections;
    final first = c.logout();
    final repeated = c.logout();
    await Future<void>.delayed(Duration.zero);
    await c.connectServer('https://other.example.invalid');
    await c.signIn('fixture@example.invalid', 'synthetic-password');
    await c.unlockSavedDevice();
    await c.initialize();
    expect(c.switchServer(), isFalse);
    expect(g.inspections, before);
    expect(g.logins, 0);
    expect(g.restores, 1);
    expect(g.initializations, 0);
    expect(g.logouts, 1);
    g.cleanup.complete();
    await first;
    await repeated;
    expect(c.switchServer(), isTrue);
    await c.connectServer('https://other.example.invalid');
    expect(g.inspections, before + 1);
    c.dispose();
  });

  test('旧pull finally不能清除logout后新connection请求的busy', () async {
    final g = ConnectionFixture();
    final c = VaultController(gateway: g);
    await c.unlockSavedDevice();
    g.delayedPull = Completer<VaultSnapshot>();
    final oldPull = c.reload();
    await c.logout();
    g.wait = Completer<InstanceDescriptor>();
    final newConnect = c.connectServer('https://fixture.example.invalid');
    expect(c.busy, isTrue);
    g.delayedPull!.complete(
      VaultSnapshot(checkpoint: 5, environments: const [], devices: const []),
    );
    await oldPull;
    expect(c.busy, isTrue);
    await c.connectServer('https://duplicate.example.invalid');
    expect(g.inspections, 1);
    g.wait!.complete(
      const InstanceDescriptor(
        initialRegistrationAvailable: false,
        allowRegistration: true,
        emailVerificationRequired: true,
      ),
    );
    await newConnect;
    expect(c.busy, isFalse);
    expect(c.endpoint, 'https://fixture.example.invalid');
    c.dispose();
  });

  test('首屏仅connection，验证前login/register/recover导航都关闭', () async {
    final c = VaultController(gateway: ConnectionFixture());
    expect(c.location.page, VaultPage.entry);
    expect(c.navigate(VaultPage.login), isFalse);
    expect(c.navigate(VaultPage.registration), isFalse);
    expect(c.navigate(VaultPage.recovery), isFalse);
    await c.connectServer('https://fixture.example.invalid');
    expect(c.serverVerified, isTrue);
    expect(c.location.page, VaultPage.login);
    expect(c.registrationAvailable, isTrue);
    expect(c.emailVerificationRequired, isTrue);
    expect(c.environments, isEmpty);
    c.dispose();
  });

  test('首账号默认register，正常实例关闭注册隐藏并拒绝route', () async {
    final g = ConnectionFixture();
    final c = VaultController(gateway: g);
    (g.response as Map)['initialRegistrationAvailable'] = true;
    (g.response as Map)['allowRegistration'] = false;
    await c.connectServer('https://fixture.example.invalid');
    expect(c.location.page, VaultPage.registration);
    expect(c.registrationAvailable, isTrue);
    c.switchServer();
    (g.response as Map)['initialRegistrationAvailable'] = false;
    await c.connectServer('https://fixture.example.invalid');
    expect(c.location.page, VaultPage.login);
    expect(c.registrationAvailable, isFalse);
    expect(c.navigate(VaultPage.registration), isFalse);
    c.dispose();
  });

  test('普通200错误JSON/产品/major2/缺bool留connection并可retry', () async {
    for (final invalid in [
      {'status': 'ok'},
      {'product': 'other', 'status': 'experimental'},
      {
        'product': 'harmonia',
        'status': 'experimental',
        'protocol': {
          'supportedMajors': [2],
          'capabilities': <String>[],
        },
      },
      {
        'product': 'harmonia',
        'status': 'experimental',
        'protocol': {
          'supportedMajors': [1],
          'capabilities': <String>[],
        },
        'initialRegistrationAvailable': 'true',
        'allowRegistration': true,
        'emailVerificationRequired': true,
      },
    ]) {
      final g = ConnectionFixture()..response = invalid;
      final c = VaultController(gateway: g);
      await c.connectServer('https://fixture.example.invalid');
      expect(c.serverVerified, isFalse);
      expect(c.location.page, VaultPage.entry);
      expect(c.error, isNotNull);
      c.dispose();
    }
  });

  test('快速Next只一次，异步结果跨logout失效不导航', () async {
    final g = ConnectionFixture()..wait = Completer<InstanceDescriptor>();
    final c = VaultController(gateway: g);
    final first = c.connectServer('https://fixture.example.invalid');
    await c.connectServer('https://other.example.invalid');
    expect(g.inspections, 1);
    await c.logout();
    g.wait!.complete(
      const InstanceDescriptor(
        initialRegistrationAvailable: false,
        allowRegistration: true,
        emailVerificationRequired: true,
      ),
    );
    await first;
    expect(c.serverVerified, isFalse);
    expect(c.location.page, VaultPage.entry);
    c.dispose();
  });

  test('logout保留验证地址到login；switch关闭旧connection但保留可编辑地址', () async {
    final c = VaultController(gateway: ConnectionFixture());
    await c.connectServer('https://fixture.example.invalid');
    await c.unlockSavedDevice();
    await c.logout();
    expect(c.endpoint, 'https://fixture.example.invalid');
    expect(c.location.page, VaultPage.login);
    expect(c.switchServer(), isTrue);
    expect(c.serverVerified, isFalse);
    expect(c.location.page, VaultPage.entry);
    expect(c.navigate(VaultPage.login), isFalse);
    c.dispose();
  });

  test('App锁coldstart拒绝路由，unlock只entry不login或trusted', () async {
    final g = PrivacyFixture();
    final c = VaultController(gateway: g);
    await c.initialize();
    expect(c.privacyLocked, isTrue);
    expect(c.canEnterVault, isFalse);
    expect(c.openDeepLink(Uri.parse('harmonia://settings')), isFalse);
    await c.unlockPrivacy();
    expect(c.privacyLocked, isFalse);
    expect(c.sessionStage, SessionStage.signedOut);
    expect(c.canEnterVault, isFalse);
    c.dispose();
  });

  test('取消系统认证仍locked，无PIN降级或设备信任', () async {
    final g = PrivacyFixture()..cancelled = true;
    final c = VaultController(gateway: g);
    await c.initialize();
    await c.unlockPrivacy();
    expect(g.unlocks, 1);
    expect(c.privacyLocked, isTrue);
    expect(c.sessionStage, SessionStage.signedOut);
    expect(c.error, contains('AUTH_CANCELLED'));
    c.dispose();
  });

  test('系统窗口inactive只遮罩，return不循环锁；真实后台需重解锁', () async {
    final g = PrivacyFixture()
      ..state = const AppPrivacyStatus(
        enabled: true,
        locked: false,
        systemPromptInFlight: true,
      );
    final c = VaultController(gateway: g);
    await c.initialize();
    await c.unlockSavedDevice();
    c.onLifecycleState(AppLifecycleState.inactive);
    expect(c.privacyObscured, isTrue);
    expect(c.environments, isEmpty);
    expect(c.privacyLocked, isFalse);
    c.onLifecycleState(AppLifecycleState.resumed);
    expect(c.privacyObscured, isFalse);
    expect(c.canEnterVault, isTrue);
    g.state = const AppPrivacyStatus(
      enabled: true,
      locked: false,
      systemPromptInFlight: false,
    );
    c.onLifecycleState(AppLifecycleState.paused);
    c.onLifecycleState(AppLifecycleState.resumed);
    expect(c.privacyLocked, isTrue);
    expect(c.environments, isEmpty);
    expect(
      c.openDeepLink(Uri.parse('harmonia://environment/fixture-env')),
      isFalse,
    );
    c.dispose();
  });
}
