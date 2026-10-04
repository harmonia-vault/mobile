import 'pending_pairing_presentation.dart';

class PendingPairingSnapshot {
  PendingPairingSnapshot({
    required this.accountId,
    required this.accountGeneration,
    required this.approverDeviceId,
    required this.certificateVersion,
    required Iterable<String> capabilities,
    required Iterable<PendingPairingHint> requests,
  }) : capabilities = List.unmodifiable(capabilities),
       requests = List.unmodifiable(requests);
  final String accountId,
      accountGeneration,
      approverDeviceId,
      certificateVersion;
  final List<String> capabilities;
  final List<PendingPairingHint> requests;
  bool get authoritativeForApproval => false;
}

abstract interface class PendingPairingGateway {
  bool get pendingPairingsAvailable;

  /// 每次由native完成新Boot/Pull及当前管理员验证，不能用缓存Admin替代。
  Future<PendingPairingSnapshot> pendingPairingRequests();

  /// 退役本次读取的晚到结果，不取消服务器请求或删除原pairingId。
  void retirePendingPairingResults();
}
