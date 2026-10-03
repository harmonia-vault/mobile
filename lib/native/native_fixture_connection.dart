import 'dart:convert';
import 'dart:io';

import '../vault_controller.dart';

/// 仅本机构造的debug测试flavor只读投影，不是账号或设备信任证明。
class ProductFixtureConnection {
  ProductFixtureConnection._(this.endpoint, this._context);
  final String endpoint;
  final SecurityContext _context;
  static ProductFixtureConnection fromNative(
    Map<String, Object?> value, {
    required bool debugBuild,
  }) {
    const fields = {'version', 'productFixture', 'endpoint', 'caPem'};
    final endpoint = value['endpoint'], ca = value['caPem'];
    if (!debugBuild ||
        value.length != fields.length ||
        value.keys.any((key) => !fields.contains(key)) ||
        value['version'] != 1 ||
        value['productFixture'] != true ||
        endpoint is! String ||
        ca is! String ||
        ca.isEmpty ||
        utf8.encode(ca).length > 65536 ||
        !ca.contains('-----BEGIN CERTIFICATE-----') ||
        ca.contains('PRIVATE KEY')) {
      throw const GatewayFailure('没有有效的debug测试flavor证明，未加入测试CA。');
    }
    final uri = Uri.tryParse(endpoint);
    if (uri == null ||
        uri.scheme != 'https' ||
        !{'127.0.0.1', 'localhost', '10.0.2.2', '::1'}.contains(uri.host) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        endpoint.trim() != endpoint ||
        endpoint.length > 2048) {
      throw const GatewayFailure('测试CA只能绑定原生固定的loopback HTTPS地址。');
    }
    try {
      final context = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificatesBytes(utf8.encode(ca));
      return ProductFixtureConnection._(endpoint, context);
    } catch (_) {
      throw const GatewayFailure('测试公共CA格式无效，未建立TLS配置。');
    }
  }

  HttpClient clientFor(String candidate) {
    if (candidate != endpoint) {
      throw const GatewayFailure('测试CA与服务地址不匹配，拒绝任何网络请求。');
    }
    // 标准证书链和hostname验证继续生效，无badCertificateCallback。
    return HttpClient(context: _context);
  }
}
