import 'dart:convert';

import 'package:flutter/services.dart';

/// 显式证书版本与来源证明业务切片，不替换默认关闭gateway或启动UI。
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

  /// 短码只作为本次调用字节缓冲传给原生SPAKE2，结束清理可控缓冲，不持久化。
  /// approved只表示管理者批准，complete才表示已验新设备双签完成。
  Future<Map<String, Object?>> approvePairing({
    required String pairingId,
    required Uint8List shortCode,
    required List<NativeApprovalSelection> selections,
  }) async {
    try {
      return _decode(
        await _channel.invokeMethod<String>('executeApproval', {
          'command': jsonEncode({
            'version': 1,
            'operation': 'approvePairing',
            'endpoint': endpoint,
            'pairingId': pairingId,
            'selections': jsonEncode(
              selections.map((s) => s.toJson()).toList(),
            ),
          }),
          'shortCode': shortCode,
        }),
      );
    } finally {
      shortCode.fillRange(0, shortCode.length, 0);
    }
  }

  Future<Map<String, Object?>> retryApproval(String pairingId) =>
      _execute('retryApproval', {'pairingId': pairingId});
  Future<Map<String, Object?>> approvalInfo() => _execute('approvalInfo', {});
  Future<Map<String, Object?>> cancelApproval(String pairingId) =>
      _execute('cancelApproval', {'pairingId': pairingId});

  /// 显式cert3来源证明，不自动降级到首根v2。
  Future<Map<String, Object?>> approvePairingV3({
    required String pairingId,
    required Uint8List shortCode,
    required List<NativeApprovalSelection> selections,
  }) => _executeCode('executeApproval', 'approvePairingV3', shortCode, {
    'pairingId': pairingId,
    'selections': jsonEncode(selections.map((s) => s.toJson()).toList()),
  });
  Future<Map<String, Object?>> retryApprovalV3(String pairingId) =>
      _execute('retryApprovalV3', {'pairingId': pairingId});
  Future<Map<String, Object?>> approvalInfoV3() => _execute('approvalInfoV3', {});
  Future<Map<String, Object?>> cancelApprovalV3(String pairingId) =>
      _execute('cancelApprovalV3', {'pairingId': pairingId});

  /// 登录及完整PAKE同次系统认证。只有已验检查点、来源账本及同步保存
  /// 全部完成才出可信view；pending只能以原pairingId恢复。
  Future<Map<String, Object?>> enrollDeviceV3({
    required String email,
    required String password,
    required String pairingId,
    required String approverDeviceId,
    required Uint8List shortCode,
  }) => _executeCode('executeEnrollment', 'enrollDeviceV3', shortCode, {
    'email': email,
    'password': password,
    'pairingId': pairingId,
    'approverDeviceId': approverDeviceId,
  });
  Future<Map<String, Object?>> resumeEnrollmentV3(String pairingId) =>
      _execute('resumeEnrollmentV3', {'pairingId': pairingId});
  Future<Map<String, Object?>> enrollmentInfoV3() =>
      _execute('enrollmentInfoV3', {});
  Future<Map<String, Object?>> rotateEnvironmentKey(
    String environmentId,
    String id,
  ) => _execute('rotateEnvironmentKey', {'environmentId': environmentId, 'id': id});

  Future<Map<String, Object?>> _executeCode(
    String method,
    String operation,
    Uint8List shortCode,
    Map<String, String> intent,
  ) async {
    try {
      return _decode(await _channel.invokeMethod<String>(method, {
        'command': jsonEncode({
          'version': 1, 'operation': operation, 'endpoint': endpoint, ...intent,
        }),
        'shortCode': shortCode,
      }));
    } finally {
      shortCode.fillRange(0, shortCode.length, 0);
    }
  }

  /// 只返回Go已验管理元数据，不包含目录公钥、封套或原签包。
  Future<Map<String, Object?>> managementDevices(String environmentId) =>
      _execute('managementDevices', {'environmentId': environmentId});
  Future<Map<String, Object?>> prepareDeviceGrant({
    required String environmentId,
    required String subjectDeviceId,
    required String role,
    required String expiresAt,
    required String id,
  }) => _execute('prepareDeviceGrant', {
    'environmentId': environmentId, 'subjectDeviceId': subjectDeviceId,
    'role': role, 'expiresAt': expiresAt, 'id': id,
  });
  Future<Map<String, Object?>> prepareOtherDeviceRevocation({
    required String environmentId,
    required String subjectDeviceId,
    required String id,
  }) => _execute('prepareOtherDeviceRevocation', {
    'environmentId': environmentId, 'subjectDeviceId': subjectDeviceId, 'id': id,
  });
  Future<Map<String, Object?>> managementInfo() => _execute('managementInfo', {});
  /// 只能沿原id/原签包；accepted与applied分别表示，任何保存错误不报告applied。
  Future<Map<String, Object?>> retryManagement(String id) =>
      _execute('retryManagement', {'id': id});
  Future<Map<String, Object?>> cancelManagement(String id) =>
      _execute('cancelManagement', {'id': id});

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

/// 仅明确环境、角色和期限；证书、来源证明和封套由Go本地重建。
class NativeApprovalSelection {
  const NativeApprovalSelection({
    required this.environmentId,
    required this.role,
    required this.expiresAt,
  });
  final String environmentId;
  final String role;
  final String expiresAt;
  Map<String, String> toJson() => {
    'environmentId': environmentId,
    'role': role,
    'expiresAt': expiresAt,
  };
}
