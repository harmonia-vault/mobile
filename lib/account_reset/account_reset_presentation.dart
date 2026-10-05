import 'dart:typed_data';

enum AccountResetStage {
  unavailable,
  entry,
  awaitingProof,
  proofPending,
  prepared,
  unknown,
  serverComplete,
  complete,
  interrupted,
}

enum AccountResetAction {
  requestEmail,
  beginFresh,
  beginQueryOnly,
  query,
  prepare,
  complete,
  cancel,
}

/// 仅公开业务状态；没有 proof、密码、原包、token 或原生句柄。
class AccountResetPresentation {
  AccountResetPresentation({
    required this.stage,
    required this.status,
    required this.busy,
    this.accountId = '',
    this.accountGeneration = '',
    this.source = '',
    this.queryOnly = false,
    this.localCleanupConfirmed = false,
    this.error,
    this.emailRetryAt,
    Iterable<AccountResetAction> actions = const [],
  }) : actions = Set.unmodifiable(actions);
  final AccountResetStage stage;
  final String status, accountId, accountGeneration, source;
  final bool busy, queryOnly, localCleanupConfirmed;
  final String? error;
  final DateTime? emailRetryAt;
  final Set<AccountResetAction> actions;
  bool get trustedDevice => false;
  bool allows(AccountResetAction action) => actions.contains(action);
}

/// UI 只消费状态和提交明确意图；输入字节在所有出口清零，不持久保存。
/// 冷续办只有查询；cancel 不表示服务器闭锁或本机物理清理完成。
abstract interface class AccountResetActions {
  AccountResetPresentation get accountReset;
  String get accountResetFormScope;
  bool get retainAccountResetInput;
  Future<void> requestAccountResetEmail(String email);
  Future<void> beginFreshAccountReset(Uint8List emailProof);
  Future<void> queryColdAccountReset(Uint8List originalEmailProof);
  Future<void> queryOriginalAccountReset();
  Future<void> prepareAccountReset(
    Uint8List newPassword, {
    required String destructiveConfirmation,
  });
  Future<void> completeAccountReset();
  Future<void> cancelAccountResetLocally();
}
