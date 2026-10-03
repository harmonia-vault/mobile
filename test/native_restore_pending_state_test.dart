import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'native_gateway_mapping_test.dart' show PortFixture, connected;
import 'navigation_state_test.dart' show FixtureGateway;

const _firstID = 'mobile-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _secondID = 'mobile-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

PendingVaultOperation _pending(
  String id, {
  String state = 'unknown',
  bool applied = false,
}) => PendingVaultOperation(
  id: id,
  operation: 'put',
  environmentId: 'fixture-env',
  state: state,
  sequence: applied ? 8 : 0,
  applied: applied,
);

/// 合成公开元数据业务回归，不证明系统认证、Go或网络实际通过。
class _PendingGateway extends FixtureGateway implements BusinessPendingGateway {
  _PendingGateway() {
    capabilities = {
      ...capabilities,
      'businessPendingInfo',
      'retryBusinessOperation',
    };
  }
  List<PendingVaultOperation> pending = [];
  Completer<VaultSession>? delayedRestore;
  final retriedIDs = <String>[];

  @override
  Future<VaultSession> restoreSession() async =>
      delayedRestore?.future ??
      VaultSession.withBusinessPending(result, pending);

  @override
  Future<List<PendingVaultOperation>> businessPendingInfo() async =>
      List.unmodifiable(pending);

  @override
  Future<PendingVaultOperation> retryBusinessOperation(String id) async {
    if (!pending.any((item) => item.id == id && item.canRetry)) {
      throw const GatewayFailure('合成来源没有该原ID');
    }
    retriedIDs.add(id);
    pending = pending.where((item) => item.id != id).toList();
    return _pending(id, state: 'applied', applied: true);
  }
}

class _CancelledPendingPort extends PortFixture {
  @override
  Future<Map<String, Object?>> execute(
    String endpoint,
    String operation,
    Map<String, String> fields,
  ) async {
    if (operation == 'businessPendingInfo') {
      calls.add((operation, Map.of(fields)));
      throw PlatformException(code: 'AUTH_CANCELLED');
    }
    return super.execute(endpoint, operation, fields);
  }
}

void main() {
  test('冷恢复保留同次原pending ID和续办入口，不自动Pull', () async {
    final port = PortFixture()
      ..deviceExists = true
      ..pendingWrite = true
      ..originalId = _firstID;
    final gateway = await connected(port);
    final controller = VaultController(gateway: gateway);
    await controller.unlockSavedDevice();
    expect(controller.businessPending.map((item) => item.id), [_firstID]);
    expect(controller.vaultSuspended, true);
    expect(controller.phase, ConnectionPhase.blocked);
    expect(controller.canEnterVault, false);
    expect(port.calls.map((call) => call.$1), [
      'restoreSession',
      'businessPendingInfo',
    ]);
    expect(controller.error, isNull);
    controller.dispose();
  });

  test('恢复附带的typed列表不可变，无额外查询且合法底层Pull仍可调用', () async {
    final port = PortFixture()
      ..deviceExists = true
      ..pendingWrite = true
      ..originalId = _firstID;
    final gateway = await connected(port);
    final session = await gateway.restoreSession();
    expect(session.accountId, 'account-fixture');
    expect(session.accountGeneration, '1');
    expect(session.businessPending.single.id, _firstID);
    expect(
      () => session.businessPending.clear(),
      throwsA(isA<UnsupportedError>()),
    );
    port.pendingWrite = false;
    expect(session.businessPending.single.id, _firstID);
    expect(port.calls.map((call) => call.$1), [
      'restoreSession',
      'businessPendingInfo',
    ]);
    // 已验只读Pull不等于原ID已解决；该修复不放宽或禁用Go只读语义。
    await gateway.pull();
    expect(port.calls.last.$1, 'pull');
  });

  test('reload不能改blocked phase或隐藏续办ID', () async {
    final gateway = _PendingGateway()..pending = [_pending(_firstID)];
    final controller = VaultController(gateway: gateway);
    await controller.unlockSavedDevice();
    await controller.reload();
    expect(controller.phase, ConnectionPhase.blocked);
    expect(controller.vaultSuspended, true);
    expect(controller.businessPending.single.id, _firstID);
    expect(gateway.reads, 0);
    expect(gateway.retriedIDs, isEmpty);
    controller.dispose();
  });

  test('两个原ID仅续办指定一笔，另一笔仍可达；全部解决后才自动Pull', () async {
    final gateway = _PendingGateway()
      ..pending = [_pending(_firstID), _pending(_secondID)];
    final controller = VaultController(gateway: gateway);
    await controller.unlockSavedDevice();
    await controller.retryBusinessPending(_firstID);
    expect(gateway.retriedIDs, [_firstID]);
    expect(controller.businessPending.single.id, _secondID);
    expect(controller.businessPending.single.canRetry, true);
    expect(controller.phase, ConnectionPhase.blocked);
    expect(controller.canEnterVault, false);
    expect(gateway.reads, 0);
    await controller.queryBusinessPending();
    expect(controller.businessPending.single.id, _secondID);
    expect(gateway.retriedIDs, [_firstID]);
    await controller.retryBusinessPending(_secondID);
    expect(gateway.retriedIDs, [_firstID, _secondID]);
    expect(controller.businessPending, isEmpty);
    expect(controller.canEnterVault, true);
    expect(controller.phase, ConnectionPhase.online);
    expect(gateway.reads, 1);
    expect(controller.error, isNull);
    controller.dispose();
  });

  test('无pending或canRetry false按正常可信恢复读取', () async {
    for (final pending in <List<PendingVaultOperation>>[
      [],
      [_pending(_firstID, state: 'canceled')],
    ]) {
      final gateway = _PendingGateway()..pending = pending;
      final controller = VaultController(gateway: gateway);
      await controller.unlockSavedDevice();
      expect(controller.canEnterVault, true);
      expect(controller.vaultSuspended, false);
      expect(controller.phase, ConnectionPhase.online);
      expect(controller.businessPending.any((item) => item.canRetry), false);
      expect(gateway.reads, 1);
      expect(controller.error, isNull);
      controller.dispose();
    }
  });

  test('metadata认证取消不发布部分恢复结果，不解锁或自动Pull', () async {
    final port = _CancelledPendingPort()
      ..deviceExists = true
      ..pendingWrite = true
      ..originalId = _firstID;
    final gateway = await connected(port);
    final controller = VaultController(gateway: gateway);
    await controller.unlockSavedDevice();
    expect(controller.sessionStage, SessionStage.signedOut);
    expect(controller.canEnterVault, false);
    expect(controller.businessPending, isEmpty);
    expect(controller.error, isNotNull);
    expect(port.calls.map((call) => call.$1), [
      'restoreSession',
      'businessPendingInfo',
    ]);
    controller.dispose();
  });

  test('账号或代际替换先清旧pending，旧ID不能续办', () async {
    for (final nextScope in [
      ('account-other', '1'),
      ('account-fixture', '2'),
    ]) {
      final gateway = _PendingGateway()..pending = [_pending(_firstID)];
      final controller = VaultController(gateway: gateway);
      await controller.unlockSavedDevice();
      gateway
        ..result = VaultSession(
          SessionStage.trusted,
          accountId: nextScope.$1,
          accountGeneration: nextScope.$2,
        )
        ..pending = [];
      await controller.unlockSavedDevice();
      expect(controller.businessPending, isEmpty);
      expect(controller.canEnterVault, true);
      expect(gateway.reads, 1);
      await controller.retryBusinessPending(_firstID);
      expect(gateway.retriedIDs, isEmpty);
      expect(controller.error, isNotNull);
      controller.dispose();
    }
  });

  test('退出后迟到的可信pending结果不能复活账号或原入口', () async {
    final gateway = _PendingGateway()
      ..delayedRestore = Completer<VaultSession>();
    final controller = VaultController(gateway: gateway);
    final restoring = controller.unlockSavedDevice();
    await controller.logout();
    gateway.delayedRestore!.complete(
      VaultSession.withBusinessPending(gateway.result, [_pending(_firstID)]),
    );
    await restoring;
    expect(controller.sessionStage, SessionStage.signedOut);
    expect(controller.businessPending, isEmpty);
    expect(controller.canEnterVault, false);
    expect(gateway.reads, 0);
    expect(gateway.logouts, 1);
    controller.dispose();
  });
}
