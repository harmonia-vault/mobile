import 'dart:convert';

import 'package:flutter/services.dart';

/// 单次本地输入请求；operation只有操作名，无值、账户密码、签包或句柄。
class LocalPINPromptRequest {
  const LocalPINPromptRequest({
    required this.setup,
    required this.operation,
    this.delaySeconds = 0,
  });
  final bool setup;
  final String operation;
  final int delaySeconds;
}

/// 可控缓冲结束必须清理，不缓存到controller或磁盘。
class LocalPINInput {
  LocalPINInput(this.pin, {this.reentry});
  final Uint8List pin;
  final Uint8List? reentry;
  void clear() {
    pin.fillRange(0, pin.length, 0);
    reentry?.fillRange(0, reentry!.length, 0);
  }

  @override
  String toString() => '<single-operation PIN input>';
}

typedef LocalPINPrompt = Future<LocalPINInput?> Function(
  LocalPINPromptRequest request,
);
typedef LocalPINForgetPrompt = Future<bool> Function();

enum LocalProtectionMode { none, system, pin, blocked }

class LocalProtectionStatus {
  const LocalProtectionStatus({
    required this.mode,
    required this.systemCapability,
    required this.deviceExists,
    required this.pinSetupAvailable,
    required this.upgradeRequired,
    required this.pinWorkflowReady,
    required this.pinForgetAvailable,
    this.delaySeconds = 0,
  });
  final LocalProtectionMode mode;
  final String systemCapability;
  final bool deviceExists,
      pinSetupAvailable,
      upgradeRequired,
      pinWorkflowReady,
      pinForgetAvailable;
  final int delaySeconds;
  static LocalProtectionStatus parse(Map<String, Object?> value) {
    const fields = {
      'version',
      'profile',
      'mode',
      'systemCapability',
      'deviceExists',
      'pinSetupAvailable',
      'upgradeRequired',
      'pinWorkflowReady',
      'delaySeconds',
      'pinForgetAvailable',
    };
    if (value.keys.toSet().difference(fields).isNotEmpty ||
        value.length != fields.length ||
        value['version'] != 1 ||
        value['profile'] != 'harmonia/local-protection/v1') {
      throw const FormatException('本机保护状态协议无效。');
    }
    final mode = switch (value['mode']) {
      'none' => LocalProtectionMode.none,
      'system' => LocalProtectionMode.system,
      'pin' => LocalProtectionMode.pin,
      'blocked' => LocalProtectionMode.blocked,
      _ => throw const FormatException('本机保护模式无效。'),
    };
    final system = value['systemCapability'];
    final delay = value['delaySeconds'];
    for (final name in [
      'deviceExists',
      'pinSetupAvailable',
      'upgradeRequired',
      'pinWorkflowReady',
      'pinForgetAvailable',
    ]) {
      if (value[name] is! bool) throw const FormatException('本机保护状态字段无效。');
    }
    if (!const {'SYSTEM_READY', 'NO_SYSTEM_AUTH', 'BLOCKED'}.contains(system) ||
        delay is! int ||
        delay < 0 ||
        delay > 600) {
      throw const FormatException('本机保护资格或等待时间无效。');
    }
    if (value['pinSetupAvailable'] == true &&
        (mode != LocalProtectionMode.none ||
            system != 'NO_SYSTEM_AUTH' ||
            value['deviceExists'] == true ||
            value['upgradeRequired'] == true)) {
      throw const FormatException('不允许从现有保护模式降级为PIN。');
    }
    if (value['pinWorkflowReady'] == true &&
        (mode != LocalProtectionMode.pin ||
            system != 'NO_SYSTEM_AUTH' ||
            value['deviceExists'] != true ||
            value['upgradeRequired'] == true ||
            value['pinSetupAvailable'] == true)) {
      throw const FormatException('PIN业务能力与实际保护范围不一致。');
    }
    if (value['pinForgetAvailable'] == true &&
        (value['deviceExists'] != true ||
            !const {
              LocalProtectionMode.pin,
              LocalProtectionMode.blocked,
            }.contains(mode))) {
      throw const FormatException('PIN清理资格与所属保护状态不一致。');
    }
    return LocalProtectionStatus(
      mode: mode,
      systemCapability: system as String,
      deviceExists: value['deviceExists'] as bool,
      pinSetupAvailable: value['pinSetupAvailable'] as bool,
      upgradeRequired: value['upgradeRequired'] as bool,
      pinWorkflowReady: value['pinWorkflowReady'] as bool,
      pinForgetAvailable: value['pinForgetAvailable'] as bool,
      delaySeconds: delay,
    );
  }
}

/// UI只提供当次输入/本地清理确认。资格、模式、授权均由原生重新验证。
abstract interface class LocalProtectionGateway {
  LocalProtectionStatus? get localProtectionStatus;
  void bindLocalPINCallbacks({
    required LocalPINPrompt prompt,
    required LocalPINForgetPrompt confirmForget,
  });
  Future<void> refreshLocalProtection();
  Future<void> setupLocalPIN();
  Future<void> forgetLocalPIN();
}

/// 完整意图与本次PIN分开传输；不接本地信任布尔值、lease或包装材料。
class NativePINAdapter {
  const NativePINAdapter(
    this.endpoint, {
    MethodChannel channel = const MethodChannel('org.harmoniavault/native/v1'),
    // 保持可注入测试channel的公开参数名。
    // ignore: prefer_initializing_formals
  }) : _channel = channel;
  final String endpoint;
  final MethodChannel _channel;
  Future<LocalProtectionStatus> information() async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'localProtectionInfo',
      {'version': 1, 'endpoint': endpoint},
    );
    if (result == null) throw const FormatException('本机保护状态缺失。');
    return LocalProtectionStatus.parse(result);
  }

  Future<Map<String, Object?>> setup(LocalPINInput input) async {
    try {
      if (input.reentry == null) throw const FormatException('设置PIN须完整重输。');
      return _decode(
        await _channel.invokeMethod<String>('setupLocalPIN', {
          'version': 1,
          'endpoint': endpoint,
          'pin': input.pin,
          'reentry': input.reentry,
        }),
      );
    } finally {
      input.clear();
    }
  }

  Future<Map<String, Object?>> execute(
    String operation,
    Map<String, String> fields,
    LocalPINInput input,
  ) => _execute('executePINWorkflow', operation, fields, input);
  Future<Map<String, Object?>> approve(
    String operation,
    Map<String, String> fields,
    LocalPINInput input,
    Uint8List shortCode,
  ) => _execute(
    'executePINApproval',
    operation,
    fields,
    input,
    shortCode: shortCode,
  );
  Future<Map<String, Object?>> enroll(
    String operation,
    Map<String, String> fields,
    LocalPINInput input,
    Uint8List shortCode,
  ) => _execute(
    'executePINEnrollment',
    operation,
    fields,
    input,
    shortCode: shortCode,
  );
  Future<Map<String, Object?>> _execute(
    String method,
    String operation,
    Map<String, String> fields,
    LocalPINInput input, {
    Uint8List? shortCode,
  }) async {
    try {
      if (fields.keys.any(
        const {
          'version',
          'endpoint',
          'operation',
          'pin',
          'shortCode',
          'mode',
          'trusted',
        }.contains,
      )) {
        throw const FormatException('意图不能替换版本、服务、操作或认证范围。');
      }
      final raw = await _channel.invokeMethod<String>(method, {
        'version': 1,
        'command': jsonEncode({
          'version': 1,
          'endpoint': endpoint,
          'operation': operation,
          ...fields,
        }),
        'pin': input.pin,
        'shortCode': ?shortCode,
      });
      return _decode(raw);
    } finally {
      input.clear();
      shortCode?.fillRange(0, shortCode.length, 0);
    }
  }

  Future<void> forget() async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'forgetLocalPIN',
      {'version': 1, 'endpoint': endpoint},
    );
    if (result == null ||
        result.keys.toSet().difference(const {
          'version',
          'cleared',
          'trustedDevice',
        }).isNotEmpty ||
        result.length != 3 ||
        result['version'] != 1 ||
        result['cleared'] != true ||
        result['trustedDevice'] != false) {
      throw const FormatException('本机清理未确认；不能报告退出成功。');
    }
  }

  Map<String, Object?> _decode(String? raw) {
    if (raw == null || utf8.encode(raw).length > 16 * 1024 * 1024) {
      throw const FormatException('原生结果缺失或过大。');
    }
    final result = jsonDecode(raw);
    if (result is! Map<String, dynamic> || result['version'] != 1) {
      throw const FormatException('原生PIN结果协议无效。');
    }
    return Map.unmodifiable(result);
  }
}
