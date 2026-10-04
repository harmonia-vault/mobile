import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/navigation/vault_route_projection.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'account_reset_host_test.dart' as reset;
import 'management_business_test.dart' as management;
import 'pending_pairings_business_test.dart' as pending;

void main() {
  test('重置提交清旧源后仍投影原重置页，不恢复旧数据或取消原owner', () async {
    final g = reset.HostFixture(), c = await reset.host(g, trusted: true);
    addTearDown(c.dispose);
    await reset.prepared(c);
    g.reset.committing = Completer();
    final completion = c.completeAccountReset();
    expect(projectVaultPage(c), VaultPage.accountReset);
    expect(c.canEnterVault, isFalse);
    expect(c.environments, isEmpty);
    expect(c.navigate(VaultPage.environments), isFalse);
    expect(g.reset.calls.where((v) => v == 'invalidate'), isEmpty);
    g.reset.committing!.complete(reset.result(complete: true));
    await completion;
    expect(projectVaultPage(c), VaultPage.accountReset);
    expect(c.accountReset.localCleanupConfirmed, isTrue);
    expect(c.accountReset.trustedDevice, isFalse);
  });

  test('管理prepared仅原管理页面续办，canEnterVault保持关闭且其它导航拒绝', () async {
    final (c, _, _) = await management.setup();
    addTearDown(c.dispose);
    expect(c.navigate(VaultPage.deviceManagement), isTrue);
    await management.loaded(c);
    await management.grant(c);
    expect(c.canEnterVault, isFalse);
    expect(c.environments, isEmpty);
    expect(c.managementContinuationVisible, isTrue);
    expect(projectVaultPage(c), VaultPage.deviceManagement);
    expect(c.navigate(VaultPage.devices), isTrue);
    expect(projectVaultPage(c), VaultPage.deviceManagement);
    for (final p in [
      VaultPage.environments,
      VaultPage.settings,
      VaultPage.approval,
      VaultPage.accountReset,
    ]) {
      expect(c.navigate(p), isFalse);
    }
    await c.cancelOriginalManagement();
    expect(c.canEnterVault, isTrue);
    expect(c.managementContinuationVisible, isFalse);
    expect(projectVaultPage(c), VaultPage.environments);
  });

  test('真实hint只带原PairID；不补旧请求、无自动审批，变化后禁止发送', () async {
    final (c, _, f) = await pending.setup();
    addTearDown(c.dispose);
    await c.refreshPendingPairings();
    expect(c.pendingAuthorizationRequests, isEmpty);
    expect(c.pendingPairingHint('missing'), isNull);
    expect(
      c.navigate(VaultPage.pendingPairingDetail, pairingId: 'missing'),
      isFalse,
    );
    expect(
      c.navigate(VaultPage.pendingPairingDetail, pairingId: 'pair-original'),
      isTrue,
    );
    expect(projectVaultPage(c), VaultPage.pendingPairingDetail);
    expect(c.location.requestId, isNull);
    expect(c.location.pairingId, 'pair-original');
    expect(c.navigate(VaultPage.approval, pairingId: 'pair-original'), isTrue);
    expect(projectVaultPage(c), VaultPage.approval);
    final before = f.calls.length;
    final roles = {for (final e in c.environments) e.id: AccessRole.readOnly};
    await c.approveDevice(
      ApprovalDraft(
        code: '12345678',
        pairingId: 'wrong-original',
        roles: roles,
        lifetime: const Duration(hours: 1),
      ),
    );
    expect(f.calls.length, before);
    expect(c.error, isNotNull);
    f.data = pending.snapshot(rows: [pending.row(state: 'approved')]);
    await c.refreshPendingPairings();
    expect(
      c.navigate(VaultPage.pendingPairingDetail, pairingId: 'pair-original'),
      isTrue,
    );
    expect(c.navigate(VaultPage.approval, pairingId: 'pair-original'), isFalse);
    final count = f.calls.length;
    await c.approveDevice(
      ApprovalDraft(
        code: '12345678',
        pairingId: 'pair-original',
        roles: roles,
        lifetime: const Duration(hours: 1),
      ),
    );
    // detail仍是hint-bound范围；状态已approved不能绕过页面再次提交。
    expect(c.pendingPairings.authoritativeForApproval, isFalse);
    expect(f.calls.length, count);
  });
}
