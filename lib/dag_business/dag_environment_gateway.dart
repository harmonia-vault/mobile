import 'dart:typed_data';

import '../recovery/recovery_gateway.dart';
import '../vault_controller.dart';

const dagEnvironmentOperations = {
  'createDAGEnvironment',
  'deleteDAGEnvironment',
  'pendingDAGEnvironments',
  'renameDAGEnvironment',
  'retryDAGEnvironment',
  'rotateDAGEnvironment',
};

abstract interface class DAGEnvironmentGateway {
  List<PendingVaultOperation> get dagEnvironmentPending;
  Future<DAGEnvironmentReply> changeDAGEnvironment(
    String operation,
    String environmentId,
    Uint8List name,
  );
  Future<DAGEnvironmentReply> retryDAGEnvironment(String originalId);
}

class DAGEnvironmentInfo {
  const DAGEnvironmentInfo({
    required this.requestId,
    required this.operation,
    required this.environmentId,
    required this.sequence,
    required this.applied,
  });
  final String requestId, operation, environmentId, sequence;
  final bool applied;
  PendingVaultOperation get projection => PendingVaultOperation(
    id: requestId,
    operation: 'environment-$operation',
    environmentId: environmentId,
    state: applied
        ? 'applied'
        : sequence == '0'
        ? 'unknown'
        : 'accepted-not-applied',
    sequence: int.parse(sequence),
    applied: applied,
  );
}

/// 只有正式验签 Pull 与整份 CAS 后的回复可携带已验 source。
class DAGEnvironmentReply {
  const DAGEnvironmentReply.applied(this.environment, this.source)
    : original = null,
      pending = null;
  const DAGEnvironmentReply.original(this.original)
    : environment = null,
      source = null,
      pending = null;
  DAGEnvironmentReply.pending(Iterable<DAGEnvironmentInfo> rows)
    : pending = List.unmodifiable(rows),
      environment = null,
      source = null,
      original = null;
  final DAGEnvironmentInfo? environment, original;
  final RecoveryTrusted? source;
  final List<DAGEnvironmentInfo>? pending;
  bool get applied => environment != null && source != null;
}
