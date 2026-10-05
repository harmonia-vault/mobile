import 'dart:typed_data';

import 'account_reset_presentation.dart';

const accountResetConfirmation = 'DELETE_OLD_VAULT';

class AccountResetFailure implements Exception {
  const AccountResetFailure(this.code);
  final AccountResetFailureCode code;
  String get message => switch (code) {
    AccountResetFailureCode.unavailable => '账号重置原生接口尚未验收，当前不能执行。',
    AccountResetFailureCode.invalidInput => '重置意图不符合固定合同，未发送。',
    AccountResetFailureCode.invalidResponse => '原生重置结果不符合合同，未确认操作。',
    AccountResetFailureCode.busy => '已有原生重置操作正在进行。',
    AccountResetFailureCode.retired => '原重置范围已结束，已丢弃晚到结果。',
    AccountResetFailureCode.queryRequired => '必须先查询原邮件证明；不能替换原请求。',
    AccountResetFailureCode.nativeRejected => '原生未确认重置结果；请查询原请求。',
    AccountResetFailureCode.localCleanupUnconfirmed => '本机清理未确认，不能报告完成或开启新流程。',
    AccountResetFailureCode.codeInvalid => '验证码不正确，请重新输入。最多可尝试 5 次。',
    AccountResetFailureCode.codeExpired => '验证码已过期，请重新发送。',
    AccountResetFailureCode.codeExhausted => '已达到 5 次尝试上限，请重新发送验证码。',
  };
  @override
  String toString() => 'AccountResetFailure(${code.name})';
}

class AccountResetEmailRateLimitFailure extends AccountResetFailure {
  const AccountResetEmailRateLimitFailure(this.retryAfterSeconds)
    : super(AccountResetFailureCode.busy);
  final int retryAfterSeconds;
  @override
  String get message => '请求过于频繁，请 $retryAfterSeconds 秒后重试。';
}

enum AccountResetFailureCode {
  unavailable,
  invalidInput,
  invalidResponse,
  busy,
  retired,
  queryRequired,
  nativeRejected,
  localCleanupUnconfirmed,
  codeInvalid,
  codeExpired,
  codeExhausted,
}

/// 当前已知 tuple 只是额外显示门；真正槽匹配仍由原生AEAD来源核验。
class AccountResetScope {
  AccountResetScope(
    this.endpoint, {
    this.accountId = '',
    this.accountGeneration = '',
  }) {
    final uri = Uri.tryParse(endpoint);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        endpoint.length > 2048 ||
        endpoint.endsWith('/') ||
        RegExp(r'[\\\x00\r\n\t]').hasMatch(endpoint) ||
        uri.path.split('/').any((s) => s == '.' || s == '..') ||
        (accountId.isEmpty != accountGeneration.isEmpty) ||
        (accountId.isNotEmpty &&
            (!resetIdentifier(accountId) ||
                !resetGeneration(accountGeneration, original: true)))) {
      throw const AccountResetFailure(AccountResetFailureCode.invalidInput);
    }
  }
  final String endpoint, accountId, accountGeneration;
  @override
  String toString() => 'AccountResetScope(opaque)';
}

bool resetIdentifier(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);
bool resetGeneration(String value, {bool original = false}) =>
    RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(value) &&
    BigInt.parse(value) <=
        BigInt.parse(
          original ? '18446744073709551614' : '18446744073709551615',
        );

class AccountResetOutcome {
  const AccountResetOutcome({
    required this.state,
    required this.accountId,
    required this.accountGeneration,
    required this.source,
    this.replayed,
  });
  final String state, accountId, accountGeneration, source;
  final bool? replayed;
  bool get complete => state == 'complete';
  @override
  String toString() => 'AccountResetOutcome(metadata)';
}

abstract interface class AccountResetGateway {
  Set<AccountResetAction> get supportedActions;

  /// 通过平台原生入口申请邮件；Dart 不直接持有 HTTP 账号凭证。
  Future<void> requestEmailProof(String endpoint, String email);
  Future<AccountResetOutcome> beginFresh(String endpoint, Uint8List proof);
  Future<AccountResetOutcome> beginQueryOnly(String endpoint, Uint8List proof);
  Future<AccountResetOutcome> query();
  Future<void> prepare(Uint8List password, String confirmation);

  /// 成功回调必须来自成熟原生匹配清理、空槽核验和worker最终drain之后。
  Future<AccountResetOutcome> complete();

  /// 只请求立即退役/取消，不表示物理清理或服务端闭锁完成。
  Future<void> invalidate();
}
