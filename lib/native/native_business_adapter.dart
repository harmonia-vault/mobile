import 'dart:convert';

import 'package:flutter/services.dart';

/// 原生业务切片。公钥不代表已可信入网；不替换默认 FailClosedGateway。
/// Dart 不实现密码学、不接收/持久化私钥或密码等价凭据。
class NativeBusinessAdapter {
  const NativeBusinessAdapter();
  static const _channel = MethodChannel('org.harmoniavault/native/v1');

  Future<Map<String, Object?>> capabilities() async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'capabilities',
    );
    if (result == null ||
        result['version'] != 1 ||
        result['realVaultReady'] != false) {
      throw const FormatException('原生桥能力结果不符合当前协议。');
    }
    return Map.unmodifiable(result);
  }

  Future<Map<String, Object?>> validateEndpoint(String endpoint) => _public({
    'version': 1,
    'operation': 'validateEndpoint',
    'endpoint': endpoint,
  });

  /// 只使用新生成的合成资料验证 Go SHA256/Ed25519/HPKE/AEAD/原生 SPAKE2。
  Future<Map<String, Object?>> verifyNativeCrypto() =>
      _public({'version': 1, 'operation': 'selfTest'});

  /// 系统认证成功后在 Go 生成独立设备钥；只返回未可信的设备公钥。
  Future<Map<String, Object?>> createProtectedDevice() async {
    return _decode(await _channel.invokeMethod<String>('createDevice'));
  }

  /// 每次调用都重新认证和解包，完成后由原生关闭 Go Device。
  Future<Map<String, Object?>> protectedPublicInfo() => _unlocked('publicInfo');
  Future<Map<String, Object?>> verifyProtectedCrypto() =>
      _unlocked('cryptoCheck');

  Future<Map<String, Object?>> _public(Map<String, Object?> command) async {
    return _decode(
      await _channel.invokeMethod<String>('executePublic', jsonEncode(command)),
    );
  }

  Future<Map<String, Object?>> _unlocked(String operation) async {
    return _decode(
      await _channel.invokeMethod<String>(
        'executeUnlocked',
        jsonEncode({'version': 1, 'operation': operation}),
      ),
    );
  }

  Map<String, Object?> _decode(String? raw) {
    if (raw == null || raw.length > 8192) {
      throw const FormatException('原生桥结果缺失或过大。');
    }
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> || value['version'] != 1) {
      throw const FormatException('原生桥结果不符合协议。');
    }
    return Map<String, Object?>.unmodifiable(value);
  }
}
