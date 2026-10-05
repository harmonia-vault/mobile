import 'dart:typed_data';

import 'account_reset_gateway.dart';
import 'account_reset_presentation.dart';

/// 已验证实例的原生网关工厂；不授UI清理、服务器重置或设备信任。
abstract interface class AccountResetGatewayProvider {
  AccountResetGateway createAccountResetGateway();
  void retireAccountResetProjection();
}

/// 同endpoint/原生scope前后门；不持有证明、密码或原请求。
class ScopedAccountResetGateway implements AccountResetGateway {
  ScopedAccountResetGateway(
    this._delegate,
    this._endpoint,
    this._isCurrent, {
    this.onCompleted,
  });
  final void Function()? onCompleted;
  final AccountResetGateway _delegate;
  final String _endpoint;
  final bool Function() _isCurrent;
  bool _retired = false;
  void _check([String? endpoint]) {
    if (_retired || !_isCurrent()) {
      throw const AccountResetFailure(AccountResetFailureCode.retired);
    }
    if (endpoint != null && endpoint != _endpoint) {
      throw const AccountResetFailure(AccountResetFailureCode.invalidInput);
    }
  }

  @override
  Set<AccountResetAction> get supportedActions =>
      _retired || !_isCurrent() ? const {} : _delegate.supportedActions;
  Future<T> _run<T>(Future<T> Function() run, [String? endpoint]) async {
    _check(endpoint);
    try {
      final out = await run();
      _check(endpoint);
      return out;
    } catch (_) {
      _check(endpoint);
      rethrow;
    }
  }

  @override
  Future<void> requestEmailProof(String endpoint, String email) =>
      _run(() => _delegate.requestEmailProof(endpoint, email), endpoint);
  @override
  Future<AccountResetOutcome> beginFresh(
    String endpoint,
    Uint8List proof,
  ) async {
    try {
      return await _run(() => _delegate.beginFresh(endpoint, proof), endpoint);
    } finally {
      proof.fillRange(0, proof.length, 0);
    }
  }

  @override
  Future<AccountResetOutcome> beginQueryOnly(
    String endpoint,
    Uint8List proof,
  ) async {
    try {
      return await _run(
        () => _delegate.beginQueryOnly(endpoint, proof),
        endpoint,
      );
    } finally {
      proof.fillRange(0, proof.length, 0);
    }
  }

  @override
  Future<AccountResetOutcome> query() => _run(_delegate.query);
  @override
  Future<void> prepare(Uint8List password, String confirmation) async {
    try {
      await _run(() => _delegate.prepare(password, confirmation));
    } finally {
      password.fillRange(0, password.length, 0);
    }
  }

  @override
  Future<AccountResetOutcome> complete() async {
    final outcome = await _run(_delegate.complete);
    if (outcome.complete) onCompleted?.call();
    return outcome;
  }

  @override
  Future<void> invalidate() {
    _retired = true; // 网络/排空前退休；即便失败也不能复开。
    return _delegate.invalidate();
  }
}
