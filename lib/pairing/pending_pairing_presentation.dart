/// 前台请求仅是提示；批准仍由原有短码配对流程独立验证。
enum PendingPairingState { pending, approved }

class PendingPairingHint {
  const PendingPairingHint({
    required this.pairingId,
    required this.initiatorDeviceId,
    required this.state,
    required this.expiresAt,
  });
  final String pairingId, initiatorDeviceId;
  final PendingPairingState state;
  final DateTime expiresAt;
}

class PendingPairingPresentation {
  PendingPairingPresentation({
    this.available = false,
    this.busy = false,
    this.status = '此设备尚未接通前台请求列表。',
    this.error,
    this.accountId,
    this.accountGeneration,
    this.approverDeviceId,
    this.certificateVersion,
    Iterable<PendingPairingHint> requests = const [],
  }) : requests = List.unmodifiable(requests);
  final bool available, busy;
  final String status;
  final String? error,
      accountId,
      accountGeneration,
      approverDeviceId,
      certificateVersion;
  final List<PendingPairingHint> requests;
  bool get authoritativeForApproval => false;
  int get pendingCount =>
      requests.where((r) => r.state == PendingPairingState.pending).length;
}

/// UI仅取真实deviceID和原pairingId；不补姓名、平台、序号或权限。
/// 选中请求只将pairingId带入既有ApprovalDraft；仍须短码和明确权限/期限。
abstract interface class PendingPairingActions {
  PendingPairingPresentation get pendingPairings;
  Future<void> refreshPendingPairings();
}
