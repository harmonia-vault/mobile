import 'dart:convert';

import 'package:flutter/services.dart';

/// 显式首根管理设备业务切片，不替换默认关闭gateway或启动UI。
/// 每次调用原生重新系统认证；状态、私钥、随机session不进入Dart。
class NativeWorkflowAdapter {
  const NativeWorkflowAdapter(this.endpoint);
  final String endpoint;
  static const _channel = MethodChannel('org.harmoniavault/native/v1');

  Future<Map<String, Object?>> profile() async =>
      _decode(await _channel.invokeMethod<String>('workflowProfile'));
  Future<Map<String, Object?>> register(String email, String password) =>
      _execute('register', {'email': email, 'password': password});
  Future<Map<String, Object?>> verifyEmail({
    required String accountId,
    required String accountGeneration,
    required String challengeId,
    required String token,
  }) => _execute('verifyEmail', {
    'accountId': accountId,
    'accountGeneration': accountGeneration,
    'challengeId': challengeId,
    'token': token,
  });

  /// Login与Begin连续执行。完整恢复码仅本次显示、重输，不持久化。
  /// id须对应稳定意图，结果未知时不得生成新id或新恢复码。
  Future<Map<String, Object?>> beginInitialization({
    required String email,
    required String password,
    required String name,
    required String id,
  }) => _execute('beginInitialization', {
    'email': email,
    'password': password,
    'name': name,
    'id': id,
  });
  Future<Map<String, Object?>> completeInitialization(String recoveryCode) =>
      _execute('completeInitialization', {'recoveryCode': recoveryCode});
  Future<Map<String, Object?>> queryInitialization() =>
      _execute('queryInitialization', {});
  Future<Map<String, Object?>> view() => _execute('view', {});
  Future<Map<String, Object?>> pull() => _execute('pull', {});
  Future<Map<String, Object?>> createEnvironment(String name, String id) =>
      _execute('createEnvironment', {'name': name, 'id': id});
  Future<Map<String, Object?>> renameEnvironment(
    String environmentId,
    String name,
    String id,
  ) => _execute('renameEnvironment', {
    'environmentId': environmentId,
    'name': name,
    'id': id,
  });
  Future<Map<String, Object?>> deleteEnvironment(
    String environmentId,
    String id,
  ) =>
      _execute('deleteEnvironment', {'environmentId': environmentId, 'id': id});
  Future<Map<String, Object?>> setVariable({
    required String environmentId,
    required String name,
    required String value,
    required String id,
  }) => _execute('setVariable', {
    'environmentId': environmentId,
    'name': name,
    'value': value,
    'id': id,
  });
  Future<Map<String, Object?>> deleteVariable(
    String environmentId,
    String name,
    String id,
  ) => _execute('deleteVariable', {
    'environmentId': environmentId,
    'name': name,
    'id': id,
  });
  Future<Map<String, Object?>> selfRevocationInfo() =>
      _execute('selfRevocationInfo', {});
  Future<Map<String, Object?>> revokeSelf(String id) =>
      _execute('revokeSelf', {'id': id});
  Future<Map<String, Object?>> logout() => _execute('logout', {});

  Future<Map<String, Object?>> _execute(
    String operation,
    Map<String, String> intent,
  ) async => _decode(
    await _channel.invokeMethod<String>(
      'executeWorkflow',
      jsonEncode({
        'version': 1,
        'operation': operation,
        'endpoint': endpoint,
        ...intent,
      }),
    ),
  );

  Map<String, Object?> _decode(String? raw) {
    if (raw == null || raw.length > 8 * 1024 * 1024) {
      throw const FormatException('原生业务结果缺失或过大。');
    }
    final result = jsonDecode(raw);
    if (result is! Map<String, dynamic> || result['version'] != 1) {
      throw const FormatException('原生业务结果不符合协议。');
    }
    return Map<String, Object?>.unmodifiable(result);
  }
}
