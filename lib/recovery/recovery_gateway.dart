import 'dart:typed_data';

import '../vault_controller.dart';
import 'recovery_presentation.dart';

const dagRecoveryProfile = 'issuer-recovery-dag-v1';

/// 每个操作都需独立实测证据和当前原生 profile；默认能力为空。
abstract interface class RecoveryGateway {
  Set<String> get recoveryCapabilities;

  /// 仅由原生明确的 protectedDeviceExists 投影；错误不能解释为空。
  bool get recoveryStateMayExist;
  Future<RecoveryReply> executeRecovery(
    String operation,
    Map<String, String> fields,
    Uint8List completeCode,
  );

  /// 同步退役晚到结果；原生取消另行排空，不删除持久原包。
  void retireRecoveryResults();
  Future<void> cancelRecoveryOwner();
}

sealed class RecoveryPayload {
  const RecoveryPayload();
}

class RecoveryOwner extends RecoveryPayload {
  const RecoveryOwner(
    this.generation,
    this.sequence,
    this.environments,
    this.rotationRequired,
    this.expiresAt,
  );
  final String generation, sequence, expiresAt;
  final int environments;
  final bool rotationRequired;
}

class RecoveryPreparation extends RecoveryPayload {
  const RecoveryPreparation(
    this.state,
    this.operationId,
    this.phase,
    this.needsOriginalOwner,
  );
  final String state, operationId, phase;
  final bool needsOriginalOwner;
}

class RecoveryPending extends RecoveryPayload {
  const RecoveryPending(
    this.state,
    this.operationId,
    this.kind,
    this.contentHash,
    this.acceptance,
    this.acceptedSequence,
    this.originalApplied,
  );
  final String state,
      operationId,
      kind,
      contentHash,
      acceptance,
      acceptedSequence;
  final bool originalApplied;
}

class RecoveryQuery extends RecoveryPayload {
  const RecoveryQuery(
    this.pending,
    this.observation,
    this.confirmation,
    this.rotationRequired,
  );
  final RecoveryPending pending;
  final String observation, confirmation;
  final bool rotationRequired;
}

/// 只读本机发现；none/unsupported 不代表已关闭。
class RecoveryResolutionDiscovery extends RecoveryPayload {
  const RecoveryResolutionDiscovery(
    this.state,
    this.operationId,
    this.targetHash,
  );
  final String state, operationId, targetHash;
  bool get supported => state == 'supported-original' || state == 'closed';
}

/// 已验证的原恢复操作处置；任何状态都不授予设备信任。
class RecoveryResolution extends RecoveryPayload {
  const RecoveryResolution({
    required this.operationId,
    required this.targetHash,
    required this.observation,
    required this.localState,
    required this.confirmation,
    required this.sequence,
  });
  final String operationId,
      targetHash,
      observation,
      localState,
      confirmation,
      sequence;
  bool get closed => localState == 'closed';
  bool get accepted => localState == 'accepted-original-confirmed';
}

class RecoveryCode extends RecoveryPayload {
  const RecoveryCode(this.value);
  final String value;
}

class RecoveryChoices extends RecoveryPayload {
  RecoveryChoices(
    this.sequence,
    this.headHash,
    Iterable<RecoveryEnvironmentChoice> environments,
  ) : environments = List.unmodifiable(environments);
  final String sequence, headHash;
  final List<RecoveryEnvironmentChoice> environments;
}

class RecoveryEnrollment extends RecoveryPayload {
  const RecoveryEnrollment(
    this.state,
    this.operationId,
    this.phase,
    this.contentHash,
    this.acceptance,
    this.acceptedSequence,
    this.originalConfirmed,
    this.needsOriginalOwner,
  );
  final String state,
      operationId,
      phase,
      contentHash,
      acceptance,
      acceptedSequence;
  final bool originalConfirmed, needsOriginalOwner;
}

class RecoveryTrusted extends RecoveryPayload {
  const RecoveryTrusted({
    required this.operationId,
    required this.contentHash,
    required this.acceptedSequence,
    required this.accountId,
    required this.accountGeneration,
    required this.deviceId,
    required this.snapshot,
  });
  final String operationId, contentHash, acceptedSequence;
  final String accountId, accountGeneration, deviceId;
  final VaultSnapshot snapshot;
  VaultSession get session => VaultSession(
    SessionStage.trusted,
    accountId: accountId,
    accountGeneration: accountGeneration,
  );
}

class RecoveryReply {
  const RecoveryReply(this.payload, {this.softError});
  final RecoveryPayload payload;

  /// 仅精确的活 owner 软错误可保留本机续办；不是已接受。
  final String? softError;
  bool get ok => softError == null;
}
