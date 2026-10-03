import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../vault_controller.dart';
import 'native_business_adapter.dart';
import 'native_workflow_adapter.dart';

/// 实验入口只探测公开能力；未验收的UI业务映射保持关闭。
/// 不以runtime profile中“已实现”替代真实界面流程验收。
class NativeVaultGateway
    implements SessionVaultGateway, InstanceConnectionGateway {
  NativeVaultGateway({required this.experimentalOptIn});
  final bool experimentalOptIn;
  Set<String> _runtimeOperations = const {};
  bool _protectedDeviceExists = false;
  @override
  bool get synthetic => false;
  @override
  Set<String> get capabilities => const {};
  Set<String> get runtimeOperations => _runtimeOperations;
  bool get protectedDeviceExists => _protectedDeviceExists;
  bool get realVaultReady => false;
  static const _reason = '原生切片已安装；界面登录与设备信任映射尚未验收，真实操作保持关闭。';
  Never _closed() => throw const GatewayFailure(_reason);

  @override
  Future<void> initialize(String endpoint) async {
    if (!experimentalOptIn) _closed();
    final business = NativeBusinessAdapter();
    if (endpoint.isNotEmpty) await business.validateEndpoint(endpoint);
    final caps = await business.capabilities();
    if (caps['goCore'] != true || caps['realVaultReady'] != false) _closed();
    _protectedDeviceExists = caps['protectedDeviceExists'] == true;
    final profile = await NativeWorkflowAdapter(endpoint).profile();
    final operations = profile['operations'];
    if (profile['experimental'] != true ||
        profile['realVaultReady'] != false ||
        operations is! List ||
        operations.any((v) => v is! String)) {
      _closed();
    }
    _runtimeOperations = Set.unmodifiable(operations.cast<String>());
  }

  @override
  Future<InstanceDescriptor> inspectInstance(String endpoint) =>
      inspectHarmoniaInstance(endpoint);

  @override
  Future<VaultSnapshot> pull() async => _closed();
  @override
  Future<void> submit(PreviewMutation mutation) async => _closed();
  @override
  Future<AccountAuthentication> loginAccount(
    String email,
    String password,
  ) async => _closed();
  @override
  Future<void> registerAccount(String email, String password) async =>
      _closed();
  @override
  Future<VaultSession> restoreSession() async => _closed();
  @override
  Future<List<AuthorizationRequest>> authorizationRequests() async => _closed();
  @override
  Future<void> approve(ApprovalDraft draft) async => _closed();
  @override
  Future<void> revoke(String deviceId) async => _closed();
  @override
  Future<void> logout() async =>
      throw const GatewayFailure('本机视图已关闭；原生退出清理映射未开放，不能确认已销毁设备资料。');
}

/// 只读取最小公开实例身份与注册开关；HTTPS状态200本身不算验证成功。
class PublicConnectionGateway extends FailClosedGateway
    implements InstanceConnectionGateway {
  @override
  Future<InstanceDescriptor> inspectInstance(String endpoint) =>
      inspectHarmoniaInstance(endpoint);
}

Future<InstanceDescriptor> inspectHarmoniaInstance(String endpoint) async {
  final base = Uri.tryParse(endpoint);
  if (base == null ||
      base.scheme != 'https' ||
      base.host.isEmpty ||
      base.userInfo.isNotEmpty ||
      base.hasQuery ||
      base.hasFragment) {
    throw const GatewayFailure('请输入无凭据、查询参数或片段的 HTTPS 服务地址。');
  }
  final path = base.path.replaceFirst(RegExp(r'/+$'), '');
  final uri = base.replace(path: '$path/instance-info');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw GatewayFailure(
        '服务验证失败（HTTP ${response.statusCode}），请确认 Harmonia 地址后重试。',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 10))) {
      bytes.addAll(chunk);
      if (bytes.length > 16384) throw const GatewayFailure('服务能力响应过大，已拒绝连接。');
    }
    return InstanceDescriptor.parse(jsonDecode(utf8.decode(bytes)));
  } on GatewayFailure {
    rethrow;
  } on HandshakeException {
    throw const GatewayFailure('HTTPS 证书验证失败，未连接服务。');
  } on SocketException {
    throw const GatewayFailure('服务不可达；离线或地址错误，尚未验证连接。');
  } on TimeoutException {
    throw const GatewayFailure('服务验证超时，尚未连接；可重试同一地址。');
  } on FormatException {
    throw const GatewayFailure('服务未返回有效的 Harmonia JSON 能力响应。');
  } finally {
    client.close(force: true);
  }
}
