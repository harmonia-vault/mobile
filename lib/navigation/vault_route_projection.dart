import '../vault_controller.dart';

/// 页面投影只缩小当前已验证来源；原管理操作不打开其它保险库内容。
VaultPage? projectVaultPage(VaultController c) {
  final p = c.location.page;
  if (c.privacyObscured) return null;
  if (c.managementContinuationVisible &&
      {VaultPage.devices, VaultPage.deviceManagement}.contains(p)) {
    return VaultPage.deviceManagement;
  }
  if (p == VaultPage.accountReset &&
      c.serverVerified &&
      !c.previewMode &&
      {SessionStage.signedOut, SessionStage.trusted}.contains(c.sessionStage)) {
    return p;
  }
  return switch (c.sessionStage) {
    SessionStage.signedOut =>
      const {
            VaultPage.login,
            VaultPage.registration,
            VaultPage.emailProof,
            VaultPage.recovery,
          }.contains(p)
          ? p
          : VaultPage.entry,
    SessionStage.deviceAuthorization =>
      p == VaultPage.initialization ? p : VaultPage.authorization,
    SessionStage.restrictedRecovery => VaultPage.recovery,
    SessionStage.trusted || SessionStage.preview =>
      !c.canEnterVault
          ? null
          : const {
              VaultPage.environments,
              VaultPage.environmentDetail,
              VaultPage.variableEditor,
              VaultPage.devices,
              VaultPage.deviceDetail,
              VaultPage.pendingPairingDetail,
              VaultPage.deviceManagement,
              VaultPage.approval,
              VaultPage.settings,
              VaultPage.accountSecurity,
              VaultPage.recoveryManagement,
            }.contains(p)
          ? p
          : VaultPage.environments,
  };
}
