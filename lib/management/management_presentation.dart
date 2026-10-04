/// P2 管理只读投影；不包含短码、签包、公钥、封套或凭据。
enum ManagementAction {
  inspect,
  loadDevices,
  prepareGrant,
  prepareRevocation,
  submitOriginal,
  cancelOriginal,
}

enum ManagementPhase {
  unavailable,
  idle,
  prepared,
  unknown,
  acceptedNotApplied,
  applied,
  cancelled,
}

enum ManagedRole {
  readOnly('只读', 'ro'),
  readWrite('读写', 'rw'),
  admin('管理', 'admin'),
  none('移除此环境授权', 'none'),
  ungranted('尚未获此环境授权', 'ungranted');

  const ManagedRole(this.label, this.wireValue);
  final String label, wireValue;
}

class ManagementExpiry {
  const ManagementExpiry.untilRevoked() : at = null;
  ManagementExpiry.until(DateTime value) : at = value.toUtc();
  final DateTime? at;
}

class ManagedDeviceAccess {
  const ManagedDeviceAccess({
    required this.deviceId,
    required this.environmentId,
    required this.role,
    required this.expiresAt,
    required this.keyVersion,
    required this.grantGeneration,
    required this.current,
  });
  final String deviceId, environmentId, keyVersion, grantGeneration;
  final ManagedRole role;
  final DateTime? expiresAt;
  final bool current;
}

class ManagementOperation {
  const ManagementOperation({
    required this.phase,
    this.id = '',
    this.kind = '',
    this.environmentId = '',
    this.subjectDeviceId = '',
    this.attempted = false,
    this.sequence = 0,
    this.acceptanceUnknown = false,
    this.requestExpiresAt,
  });
  final ManagementPhase phase;
  final String id, kind, environmentId, subjectDeviceId;
  final bool attempted, acceptanceUnknown;
  final int sequence;

  /// 仅 revoke 原请求证明期限，不是设备授权期限；grant 冷 metadata 不含目标角色/期限。
  final DateTime? requestExpiresAt;
  bool get unresolved => {
    ManagementPhase.prepared,
    ManagementPhase.unknown,
    ManagementPhase.acceptedNotApplied,
  }.contains(phase);
}

class ManagementPresentation {
  ManagementPresentation({
    this.busy = false,
    this.environmentId = '',
    this.status = '设备管理尚无已验证能力。',
    this.error,
    this.operation = const ManagementOperation(
      phase: ManagementPhase.unavailable,
    ),
    Iterable<ManagedDeviceAccess> devices = const [],
    Iterable<ManagementAction> actions = const [],
  }) : devices = List.unmodifiable(devices),
       actions = Set.unmodifiable(actions);
  final bool busy;
  final String environmentId, status;
  final String? error;
  final ManagementOperation operation;
  final List<ManagedDeviceAccess> devices;
  final Set<ManagementAction> actions;
  bool allows(ManagementAction action) => actions.contains(action);
}

/// UI 只提交明确意图；新ID由gateway一次生成，重试/取消只用已保护原ID。
abstract interface class ManagementActions {
  ManagementPresentation get management;
  Future<void> inspectDeviceManagement();
  Future<void> loadManagedDevices(String environmentId);
  Future<void> prepareManagedDeviceGrant({
    required String environmentId,
    required String subjectDeviceId,
    required ManagedRole role,
    required ManagementExpiry expiry,
  });
  Future<void> prepareManagedDeviceRevocation({
    required String environmentId,
    required String subjectDeviceId,
    required bool destructiveConfirmed,
  });
  Future<void> submitOriginalManagement();
  Future<void> cancelOriginalManagement();
}
