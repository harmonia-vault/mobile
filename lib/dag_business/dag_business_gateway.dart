import 'dart:typed_data';

import '../recovery/recovery_gateway.dart';
import '../vault_controller.dart';

const dagBusinessOperations = {
  'deleteDAGVariable',
  'pendingDAGWrites',
  'putDAGVariable',
  'retryDAGWrite',
};

/// 明确的已恢复来源业务边界；普通 writer 与恢复事务入口不作替代。
abstract interface class DAGBusinessGateway {
  bool get dagBusinessSelected;
  List<PendingVaultOperation> get dagBusinessPending;
  Future<DAGBusinessReply> writeDAGVariable(
    String environmentId,
    String name,
    Uint8List value, {
    required bool delete,
  });
  Future<DAGBusinessReply> retryDAGBusinessWrite(String originalId);
  void retireDAGBusinessResults();
}

class DAGWriteReceipt {
  DAGWriteReceipt(this.requestId, Iterable<String> sequences)
    : sequences = List.unmodifiable(sequences);
  final String requestId;
  final List<String> sequences;
}

class DAGPendingWrite {
  DAGPendingWrite({
    required this.requestId,
    required this.operation,
    required this.environmentId,
    required this.accepted,
    required this.canceled,
    required Iterable<String> sequences,
  }) : sequences = List.unmodifiable(sequences);
  final String requestId, operation, environmentId;
  final int accepted;
  final bool canceled;
  final List<String> sequences;
  PendingVaultOperation get projection => PendingVaultOperation(
    id: requestId,
    operation: operation,
    environmentId: environmentId,
    state: canceled
        ? 'canceled'
        : accepted == 1
        ? 'accepted-not-applied'
        : 'unknown',
    sequence: sequences.isEmpty ? 0 : int.parse(sequences.single),
    applied: false,
  );
}

/// source 只存在于正式验签 Pull 和最终整份 CAS 成功的结果。
class DAGBusinessReply {
  const DAGBusinessReply.applied(this.write, this.source)
    : original = null,
      pending = null;
  const DAGBusinessReply.original(this.original)
    : write = null,
      source = null,
      pending = null;
  DAGBusinessReply.pending(Iterable<DAGPendingWrite> values)
    : pending = List.unmodifiable(values),
      write = null,
      source = null,
      original = null;
  final DAGWriteReceipt? write;
  final RecoveryTrusted? source;
  final DAGPendingWrite? original;
  final List<DAGPendingWrite>? pending;
  bool get applied => write != null && source != null;
}
