import 'dart:typed_data';

/// 恢复界面只读业务投影。无密钥、恢复码、密码、token或原生句柄。
enum RecoveryStage {
  entry,
  restricted,
  codePrepared,
  transitionPending,
  transitionConfirmed,
  enrollmentChoices,
  enrollmentPending,
  enrollmentConfirmed,
  trusted,
  closed,
  interrupted,
}

enum RecoveryAction {
  inspect,
  open,
  prepareCode,
  sealTransition,
  submitTransition,
  queryOriginal,
  loadChoices,
  sealEnrollment,
  submitEnrollment,
  verifyDevice,
  restoreDevice,
  pullDevice,
  cancelLocal,
  queryClosure,
  closeOriginal,
  restartAfterClosure,
}

enum RecoveryRole {
  readOnly('只读', 'ro'),
  readWrite('读写', 'rw'),
  admin('管理', 'admin');

  const RecoveryRole(this.label, this.wireValue);
  final String label, wireValue;
}

class RecoveryEnvironmentChoice {
  const RecoveryEnvironmentChoice({
    required this.environmentId,
    required this.keyVersion,
  });
  final String environmentId, keyVersion;
}

/// 两个构造都必须由用户明确选择；没有默认永久或默认期限。
class RecoveryExpiry {
  const RecoveryExpiry.untilRevoked() : at = null;
  RecoveryExpiry.until(DateTime value) : at = value.toUtc();
  final DateTime? at;
}

class RecoverySelection {
  const RecoverySelection({
    required this.environmentId,
    required this.keyVersion,
    required this.role,
    required this.expiry,
  });
  final String environmentId, keyVersion;
  final RecoveryRole role;
  final RecoveryExpiry expiry;
}

class RecoveryPresentation {
  RecoveryPresentation({
    this.stage = RecoveryStage.entry,
    this.status = '恢复业务尚未接通；没有执行任何恢复操作。',
    this.busy = false,
    this.operationId,
    this.acceptedSequence,
    this.preparationPhase,
    this.observation = 'unknown',
    this.confirmation = 'none',
    this.needsOriginalOwner = false,
    this.ownerAvailable = false,
    this.newCodeAvailable = false,
    this.newCodeVisible = false,
    this.trustedDevice = false,
    this.error,
    Iterable<RecoveryEnvironmentChoice> choices = const [],
    Iterable<RecoveryAction> actions = const [],
    Map<RecoveryAction, String> blockedReasons = const {},
  }) : choices = List.unmodifiable(choices),
       actions = Set.unmodifiable(actions),
       blockedReasons = Map.unmodifiable(blockedReasons);

  final RecoveryStage stage;
  final String status, observation, confirmation;
  final String? operationId, acceptedSequence, preparationPhase, error;
  final bool busy, needsOriginalOwner, ownerAvailable;
  final bool newCodeAvailable, newCodeVisible, trustedDevice;
  final List<RecoveryEnvironmentChoice> choices;
  final Set<RecoveryAction> actions;
  final Map<RecoveryAction, String> blockedReasons;
  bool allows(RecoveryAction action) => actions.contains(action);
  String unavailableReason(RecoveryAction action) =>
      blockedReasons[action] ?? '此步骤尚无已验证的原生能力。';
}

/// VaultController实现此合同；UI不创建UUID/hash、不做加密、不传原生scope。
/// 所有码参数均被消费，完成/异常后清零可控buffer。不得复用同一buffer。
/// 密码和显示字符串仅当次RAM使用；不承诺Dart String可彻底擦除。
abstract interface class RecoveryActions {
  RecoveryPresentation get recovery;
  String? get recoveryCodeForDisplay;
  String get sensitiveFormScope;
  bool get retainSensitiveForm;

  Future<void> inspectRecovery();
  Future<void> openRecovery({
    required String email,
    required String password,
    required Uint8List currentCode,
  });
  Future<void> prepareRecoveryCode();
  void setRecoveryCodeVisible(bool visible);
  Future<void> sealRecoveryTransition(Uint8List completeReentry);
  Future<void> submitRecoveryTransition();
  Future<void> queryRecoveryOriginal(Uint8List completeCurrentCode);
  Future<void> loadRecoveryChoices();
  Future<void> sealRecoveryEnrollment(List<RecoverySelection> selections);
  Future<void> submitRecoveryEnrollment();
  Future<void> verifyRecoveredDevice();
  Future<void> restoreRecoveredDevice();
  Future<void> pullRecoveredDevice();
  Future<void> cancelRecoveryLocally();
  Future<void> queryRecoveryClosure(Uint8List completeCurrentCode);
  Future<void> closeRecoveryOriginal(
    Uint8List completeCurrentCode, {
    required bool destructiveConfirmed,
  });
  Future<void> restartRecoveryAfterClosure(Uint8List completeCurrentCode);
}
