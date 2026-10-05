import 'package:flutter/services.dart';

import '../account_reset/account_reset_gateway.dart';
import '../account_reset/account_reset_presentation.dart';
import 'native_account_reset_adapter.dart';

/// 固定七动作真实Channel端口；未编译/未验收时adapter仍默认关闭。
/// 不接收CA、namespace、账号声明、owner或清理授权。
class MethodChannelAccountResetPort
    implements NativeAccountResetPort, NativeAccountResetMailPort {
  const MethodChannelAccountResetPort([
    this._channel = const MethodChannel('org.harmoniavault/native/v1'),
  ]);
  final MethodChannel _channel;

  Future<String> _json(String method, [Map<String, Object>? args]) async {
    try {
      final value = await _channel.invokeMethod<String>(method, args);
      if (value == null) {
        throw const AccountResetFailure(
          AccountResetFailureCode.invalidResponse,
        );
      }
      return value;
    } on MissingPluginException {
      throw const AccountResetFailure(AccountResetFailureCode.unavailable);
    } on AccountResetFailure {
      rethrow;
    } on PlatformException catch (error) {
      throw AccountResetFailure(switch (error.code) {
        'EMAIL_CODE_INVALID' => AccountResetFailureCode.codeInvalid,
        'EMAIL_CODE_EXPIRED' => AccountResetFailureCode.codeExpired,
        'EMAIL_CODE_EXHAUSTED' => AccountResetFailureCode.codeExhausted,
        _ => AccountResetFailureCode.nativeRejected,
      });
    } catch (_) {
      // 不读取/显示PlatformException的message、details或原生错误原文。
      throw const AccountResetFailure(AccountResetFailureCode.nativeRejected);
    }
  }

  @override
  Future<String> requestEmail(String endpoint, Uint8List email) async {
    try {
      return await _json('requestAccountResetEmail', {
        'endpoint': endpoint,
        'email': email,
      });
    } finally {
      email.fillRange(0, email.length, 0);
    }
  }

  @override
  Future<String> begin(String endpoint, Uint8List proof) async {
    try {
      return await _json('beginAccountReset', {
        'endpoint': endpoint,
        'proof': proof,
      });
    } finally {
      proof.fillRange(0, proof.length, 0);
    }
  }

  @override
  Future<String> beginQueryOnly(String endpoint, Uint8List proof) async {
    try {
      return await _json('beginAccountResetQueryOnly', {
        'endpoint': endpoint,
        'proof': proof,
      });
    } finally {
      proof.fillRange(0, proof.length, 0);
    }
  }

  @override
  Future<String> query() => _json('queryAccountReset');
  @override
  Future<String> prepare(Uint8List password, String confirmation) async {
    try {
      return await _json('prepareAccountReset', {
        'password': password,
        'confirmation': confirmation,
      });
    } finally {
      password.fillRange(0, password.length, 0);
    }
  }

  @override
  Future<String> complete() => _json('completeAccountReset');
  @override
  Future<void> invalidate() async {
    try {
      final result = await _channel.invokeMethod<Object?>('cancelAccountReset');
      if (result != null) {
        throw const AccountResetFailure(
          AccountResetFailureCode.invalidResponse,
        );
      }
    } on MissingPluginException {
      throw const AccountResetFailure(AccountResetFailureCode.unavailable);
    } on AccountResetFailure {
      rethrow;
    } catch (_) {
      throw const AccountResetFailure(AccountResetFailureCode.nativeRejected);
    }
  }
}

/// 只投影真实平台compiled bool；不能把它当业务/SDK验收证据。
Set<AccountResetAction> compiledAccountResetActions(
  Map<String, Object?> capabilities,
) {
  final reset = capabilities['nativeAccountReset'] == true;
  final mail = capabilities['nativeAccountResetEmailRequest'] == true;
  return Set.unmodifiable({
    if (reset)
      ...AccountResetAction.values.where(
        (a) => a != AccountResetAction.requestEmail,
      ),
    if (mail) AccountResetAction.requestEmail,
  });
}
