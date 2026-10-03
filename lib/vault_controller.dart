import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;

enum AccessRole {
  readOnly('只读'),
  readWrite('读写'),
  admin('管理');

  const AccessRole(this.label);
  final String label;
}

enum ConnectionPhase {
  preview('合成预览'),
  blocked('安全适配未接通'),
  syncing('正在拉取'),
  online('在线'),
  offline('离线');

  const ConnectionPhase(this.label);
  final String label;
}

@immutable
class VaultVariable {
  const VaultVariable({required this.name, required this.value});
  final String name;
  final String value;
}

@immutable
class VaultEnvironment {
  VaultEnvironment({
    required this.id,
    required this.name,
    required this.role,
    required List<VaultVariable> variables,
  }) : variables = List.unmodifiable(variables);
  final String id;
  final String name;
  final AccessRole role;
  final List<VaultVariable> variables;
}

@immutable
class VaultDevice {
  const VaultDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.accessSummary,
    required this.expiresLabel,
    required this.current,
  });
  final String id, name, platform, accessSummary, expiresLabel;
  final bool current;
}

@immutable
class ApprovalDraft {
  ApprovalDraft({
    required this.code,
    this.pairingId = '',
    required Map<String, AccessRole> roles,
    required this.lifetime,
  }) : roles = Map.unmodifiable(roles);
  final String code, pairingId;
  final Map<String, AccessRole> roles;
  final Duration? lifetime;
}

@immutable
class VaultSnapshot {
  VaultSnapshot({
    required this.checkpoint,
    required List<VaultEnvironment> environments,
    required List<VaultDevice> devices,
  }) : environments = List.unmodifiable(environments),
       devices = List.unmodifiable(devices);
  final int checkpoint;
  final List<VaultEnvironment> environments;
  final List<VaultDevice> devices;
}

class GatewayFailure implements Exception {
  const GatewayFailure(this.message);
  final String message;
}

// 界面只提交意图。真实适配必须在 Go 内完成权限检查、签密文、提交和验签拉取。
abstract interface class VaultGateway {
  bool get synthetic;
  Future<VaultSnapshot> pull();
  Future<void> submit(PreviewMutation mutation);
}

enum PreviewOperation {
  createEnvironment,
  renameEnvironment,
  deleteEnvironment,
  setVariable,
  deleteVariable,
}

@immutable
class PreviewMutation {
  const PreviewMutation(
    this.operation, {
    this.environmentId,
    this.name,
    this.value,
  });
  final PreviewOperation operation;
  final String? environmentId, name, value;
}

// 默认运行路径：缺少可信配对、原生密钥保护和 Go 适配时不尝试真实网络操作。
class FailClosedGateway implements VaultGateway {
  @override
  bool get synthetic => false;
  static const reason = '界面与可信设备、Go 同步及系统认证的映射尚未验收。当前不能登录、读取或修改真实保险库。';
  @override
  Future<VaultSnapshot> pull() async => throw const GatewayFailure(reason);
  @override
  Future<void> submit(PreviewMutation mutation) async =>
      throw const GatewayFailure(reason);
}

// 显式 --dart-define=HARMONIA_PREVIEW=true 才启用。无文件、网络或账号数据。
class SyntheticPreviewGateway implements VaultGateway {
  @override
  bool get synthetic => true;
  int _sequence = 7;
  final List<VaultEnvironment> _environments = [
    VaultEnvironment(
      id: 'demo-development',
      name: '开发环境',
      role: AccessRole.admin,
      variables: const [
        VaultVariable(name: 'API_URL', value: 'https://api.example.invalid'),
        VaultVariable(name: 'DEMO_TOKEN', value: 'synthetic-not-a-secret'),
      ],
    ),
    VaultEnvironment(
      id: 'demo-review',
      name: '只读示例',
      role: AccessRole.readOnly,
      variables: const [VaultVariable(name: 'LOG_LEVEL', value: 'info')],
    ),
  ];
  static const _devices = [
    VaultDevice(
      id: 'demo-phone',
      name: '示例手机',
      platform: 'Android · 合成数据',
      accessSummary: '开发环境：管理',
      expiresLabel: '演示授权，无真实效力',
      current: true,
    ),
    VaultDevice(
      id: 'demo-laptop',
      name: '示例笔记本',
      platform: 'CLI · 合成数据',
      accessSummary: '开发环境：只读',
      expiresLabel: '演示期限，无真实效力',
      current: false,
    ),
  ];
  @override
  Future<VaultSnapshot> pull() async => VaultSnapshot(
    checkpoint: _sequence,
    environments: List.of(_environments),
    devices: _devices,
  );

  @override
  Future<void> submit(PreviewMutation mutation) async {
    if (mutation.operation == PreviewOperation.createEnvironment) {
      _sequence++;
      _environments.add(
        VaultEnvironment(
          id: 'demo-$_sequence',
          name: mutation.name!,
          role: AccessRole.admin,
          variables: const [],
        ),
      );
      return;
    }
    final index = _environments.indexWhere(
      (e) => e.id == mutation.environmentId,
    );
    if (index < 0) throw const GatewayFailure('环境不存在，请重新拉取。');
    final old = _environments[index];
    final management =
        mutation.operation == PreviewOperation.renameEnvironment ||
        mutation.operation == PreviewOperation.deleteEnvironment;
    if (old.role == AccessRole.readOnly ||
        (management && old.role != AccessRole.admin)) {
      throw const GatewayFailure('当前环境角色不允许该操作。');
    }
    switch (mutation.operation) {
      case PreviewOperation.createEnvironment:
        break;
      case PreviewOperation.renameEnvironment:
        _environments[index] = VaultEnvironment(
          id: old.id,
          name: mutation.name!,
          role: old.role,
          variables: old.variables,
        );
      case PreviewOperation.deleteEnvironment:
        _environments.removeAt(index);
      case PreviewOperation.setVariable:
        final variables =
            old.variables.where((v) => v.name != mutation.name).toList()..add(
              VaultVariable(name: mutation.name!, value: mutation.value!),
            );
        variables.sort((a, b) => a.name.compareTo(b.name));
        _environments[index] = VaultEnvironment(
          id: old.id,
          name: old.name,
          role: old.role,
          variables: variables,
        );
      case PreviewOperation.deleteVariable:
        _environments[index] = VaultEnvironment(
          id: old.id,
          name: old.name,
          role: old.role,
          variables: old.variables
              .where((v) => v.name != mutation.name)
              .toList(),
        );
    }
    _sequence++;
  }
}

@immutable
class InstanceDescriptor {
  const InstanceDescriptor({
    required this.initialRegistrationAvailable,
    required this.allowRegistration,
    required this.emailVerificationRequired,
  });
  final bool initialRegistrationAvailable,
      allowRegistration,
      emailVerificationRequired;
  static InstanceDescriptor parse(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['product'] != 'harmonia' ||
        value['status'] != 'experimental') {
      throw const GatewayFailure('此服务没有提供有效的 Harmonia 产品身份。');
    }
    final protocol = value['protocol'];
    if (protocol is! Map<String, dynamic> ||
        protocol['supportedMajors'] is! List ||
        !(protocol['supportedMajors'] as List).contains(1) ||
        (protocol['supportedMajors'] as List).any((v) => v is! int || v < 1) ||
        protocol['capabilities'] is! List ||
        (protocol['capabilities'] as List).any((v) => v is! String)) {
      throw const GatewayFailure('服务协议不兼容，当前手机只支持公开 protocol major 1。');
    }
    for (final key in [
      'initialRegistrationAvailable',
      'allowRegistration',
      'emailVerificationRequired',
    ]) {
      if (value[key] is! bool) throw const GatewayFailure('服务注册能力响应不完整。');
    }
    return InstanceDescriptor(
      initialRegistrationAvailable:
          value['initialRegistrationAvailable'] as bool,
      allowRegistration: value['allowRegistration'] as bool,
      emailVerificationRequired: value['emailVerificationRequired'] as bool,
    );
  }
}

abstract interface class InstanceConnectionGateway {
  Future<InstanceDescriptor> inspectInstance(String endpoint);
}

@immutable
class AppPrivacyStatus {
  const AppPrivacyStatus({
    required this.enabled,
    required this.locked,
    required this.systemPromptInFlight,
  });
  final bool enabled, locked, systemPromptInFlight;
}

/// UI协调合同；不是原生PIN/密钥授权接口。缺少真实provider时关闭。
abstract interface class AppPrivacyGateway {
  AppPrivacyStatus get privacyStatus;
  Future<void> unlockPrivacy();
}

enum SessionStage {
  signedOut,
  deviceAuthorization,
  restrictedRecovery,
  trusted,
  preview,
}

enum VaultPage {
  entry,
  login,
  registration,
  recovery,
  initialization,
  authorization,
  environments,
  environmentDetail,
  variableEditor,
  devices,
  deviceDetail,
  approval,
  settings,
  accountSecurity,
  recoveryManagement,
}

@immutable
class VaultLocation {
  const VaultLocation(
    this.page, {
    this.environmentId,
    this.deviceId,
    this.requestId,
  });
  final VaultPage page;
  final String? environmentId, deviceId, requestId;
}

@immutable
class VaultSession {
  const VaultSession(
    this.stage, {
    this.accountId = '',
    this.accountGeneration = '',
  });
  final SessionStage stage;
  final String accountId, accountGeneration;
}

@immutable
class AccountAuthentication {
  const AccountAuthentication({
    required this.authenticated,
    required this.trustedDevice,
  });
  final bool authenticated, trustedDevice;
}

enum AuthorizationRequestStatus { pending, completed, revoked }

/// 只接收未来已核验原生来源的公开元数据，不包含短码、token或签包。
@immutable
class AuthorizationRequest {
  const AuthorizationRequest({
    required this.id,
    required this.accountId,
    required this.accountGeneration,
    required this.deviceName,
    required this.platform,
    required this.expiresAt,
    required this.sequence,
    this.status = AuthorizationRequestStatus.pending,
  });
  final String id, accountId, accountGeneration, deviceName, platform;
  final DateTime expiresAt;
  final int sequence;
  final AuthorizationRequestStatus status;
}

/// UI意图接口不是原生wire；具体方法必须由已验适配器映射，缺能力拒绝。
abstract interface class SessionVaultGateway implements VaultGateway {
  Set<String> get capabilities;
  Future<void> initialize(String endpoint);
  Future<AccountAuthentication> loginAccount(String email, String password);
  Future<void> registerAccount(String email, String password);
  Future<VaultSession> restoreSession();
  Future<void> logout();
  Future<List<AuthorizationRequest>> authorizationRequests();
  Future<void> approve(ApprovalDraft draft);
  Future<void> revoke(String deviceId);
}

class VaultController extends ChangeNotifier {
  VaultController({
    required this.gateway,
    this.allowPreview = false,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final VaultGateway gateway;
  final bool allowPreview;
  final DateTime Function() _now;
  bool _privacyMask = false, _privacyLocked = false, _privacyUnlocking = false;
  bool _busy = false,
      _disposed = false,
      _foreground = true,
      _requestsBusy = false;
  String? _activePrompt;
  int _epoch = 0, _operationSerial = 0, _cleanupSerial = 0;
  int? _activeOperation, _activeCleanup;
  Future<void>? _cleanupInFlight;
  String _endpoint = '';
  InstanceDescriptor? _instance;
  bool _nativeCleanupPending = false;
  String? _error;
  VaultSnapshot _snapshot = VaultSnapshot(
    checkpoint: 0,
    environments: const [],
    devices: const [],
  );
  ConnectionPhase _phase = ConnectionPhase.blocked;
  VaultSession _session = const VaultSession(SessionStage.signedOut);
  final List<VaultLocation> _locations = [const VaultLocation(VaultPage.entry)];
  final Map<String, AuthorizationRequest> _requests = {};
  final Map<String, int> _requestVersions = {};
  final Set<String> _prompted = {};
  final List<String> _promptQueue = [];

  bool get privacyObscured => _privacyMask || _privacyLocked;
  bool get privacyLocked => _privacyLocked;
  bool get privacyLockAvailable => gateway is AppPrivacyGateway;
  bool get serverVerified => _instance != null;
  bool get registrationAvailable =>
      _instance != null &&
      (_instance!.initialRegistrationAvailable || _instance!.allowRegistration);
  bool get emailVerificationRequired =>
      _instance?.emailVerificationRequired ?? false;
  bool get connectionAvailable => gateway is InstanceConnectionGateway;
  bool get previewMode => _session.stage == SessionStage.preview;
  bool get previewAvailable => allowPreview && gateway.synthetic;
  bool get canEnterVault =>
      !_privacyMask &&
      !_privacyLocked &&
      (_session.stage == SessionStage.trusted || previewMode);
  SessionStage get sessionStage => _session.stage;
  VaultLocation get location => _locations.last;
  bool get canGoBack => _locations.length > 1;
  bool get busy => _busy;
  String get endpoint => _endpoint;
  ConnectionPhase get phase => _phase;
  String? get error => _error;
  List<VaultEnvironment> get environments =>
      canEnterVault ? _snapshot.environments : const [];
  List<VaultDevice> get devices => canEnterVault ? _snapshot.devices : const [];
  int get checkpoint => canEnterVault ? _snapshot.checkpoint : 0;
  String get recoveryStatus => '连续恢复的 Flutter 业务映射尚未验收，当前入口不可用。';
  bool get restrictedRecovery =>
      _session.stage == SessionStage.restrictedRecovery;
  bool get authorizationRequestsAvailable =>
      supports('authorizationRequests') && !previewMode;
  bool supports(String operation) {
    if (previewMode) {
      return const {
        'createEnvironment',
        'renameEnvironment',
        'deleteEnvironment',
        'setVariable',
        'deleteVariable',
      }.contains(operation);
    }
    return gateway is SessionVaultGateway &&
        (gateway as SessionVaultGateway).capabilities.contains(operation);
  }

  List<AuthorizationRequest> get pendingAuthorizationRequests =>
      List.unmodifiable(_requests.values.where(_requestVisible));
  int get pendingAuthorizationCount => pendingAuthorizationRequests.length;
  String get requestCapabilityMessage => authorizationRequestsAvailable
      ? '仅在 App 前台检查已核验的授权请求。'
      : '授权请求列表尚未接通。当前不会自动提示或显示待审批 badge；手动配对不代表服务器待审批请求。';

  bool _requestVisible(AuthorizationRequest r) =>
      canEnterVault &&
      r.accountId == _session.accountId &&
      r.accountGeneration == _session.accountGeneration &&
      r.status == AuthorizationRequestStatus.pending &&
      r.expiresAt.isAfter(_now());

  void clearError() {
    _error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _run(Future<void> Function(int epoch) operation) async {
    if (_busy || _disposed) return;
    if (_nativeCleanupPending) {
      _error = '原生退出清理尚未确认，暂不能建立新会话或连接。';
      _notify();
      return;
    }
    if (privacyObscured) {
      _error = '先恢复应用入口，再执行此操作。';
      _notify();
      return;
    }
    _busy = true;
    _error = null;
    final token = ++_operationSerial;
    _activeOperation = token;
    final epoch = _epoch;
    _notify();
    try {
      await operation(epoch);
    } on GatewayFailure catch (failure) {
      if (epoch == _epoch) _error = failure.message;
    } catch (_) {
      if (epoch == _epoch) _error = '操作未完成。先查询原操作；未确认任何云端变更。';
    } finally {
      if (_activeOperation == token) {
        _busy = false;
        _activeOperation = null;
      }
      _notify();
    }
  }

  void _resetLocalSession() {
    _epoch++;
    _session = const VaultSession(SessionStage.signedOut);
    _snapshot = VaultSnapshot(
      checkpoint: 0,
      environments: const [],
      devices: const [],
    );
    _phase = ConnectionPhase.blocked;
    _locations
      ..clear()
      ..add(VaultLocation(serverVerified ? VaultPage.login : VaultPage.entry));
    _requests.clear();
    _requestVersions.clear();
    _prompted.clear();
    _promptQueue.clear();
    _activePrompt = null;
  }

  void _applySession(VaultSession session) {
    if (session.stage == SessionStage.preview ||
        session.stage == SessionStage.trusted &&
            (session.accountId.isEmpty || session.accountGeneration.isEmpty)) {
      throw const GatewayFailure('设备信任结果缺少已核验的账号范围，已拒绝进入保险库。');
    }
    if (session.accountId != _session.accountId ||
        session.accountGeneration != _session.accountGeneration) {
      _requests.clear();
      _requestVersions.clear();
      _prompted.clear();
      _promptQueue.clear();
      _activePrompt = null;
    }
    _session = session;
    _snapshot = VaultSnapshot(
      checkpoint: 0,
      environments: const [],
      devices: const [],
    );
    _locations
      ..clear()
      ..add(
        VaultLocation(switch (session.stage) {
          SessionStage.signedOut => VaultPage.entry,
          SessionStage.deviceAuthorization => VaultPage.authorization,
          SessionStage.restrictedRecovery => VaultPage.recovery,
          SessionStage.trusted => VaultPage.environments,
          SessionStage.preview => VaultPage.entry,
        }),
      );
  }

  Future<void> connectServer(String value) => _run((epoch) async {
    if (_session.stage != SessionStage.signedOut || _nativeCleanupPending) {
      throw const GatewayFailure('先完成原设备的退出清理，再切换服务。');
    }
    final candidate = Uri.tryParse(value.trim());
    if (candidate == null ||
        candidate.scheme != 'https' ||
        candidate.host.isEmpty ||
        candidate.userInfo.isNotEmpty ||
        candidate.hasQuery ||
        candidate.hasFragment) {
      throw const GatewayFailure('请输入无凭据、查询参数或片段的 HTTPS 服务地址。');
    }
    if (gateway is! InstanceConnectionGateway) {
      throw const GatewayFailure('公开实例验证尚未接通，不能确认服务可用。');
    }
    final verified = await (gateway as InstanceConnectionGateway)
        .inspectInstance(candidate.toString());
    if (epoch != _epoch) return;
    _endpoint = candidate.toString();
    _instance = verified;
    _locations
      ..clear()
      ..add(
        VaultLocation(
          verified.initialRegistrationAvailable
              ? VaultPage.registration
              : VaultPage.login,
        ),
      );
  });
  bool switchServer() {
    if (_session.stage != SessionStage.signedOut ||
        _busy ||
        _nativeCleanupPending) {
      return false;
    }
    _instance = null;
    _locations
      ..clear()
      ..add(const VaultLocation(VaultPage.entry));
    _notify();
    return true;
  }

  Future<void> initialize() => _run((epoch) async {
    if (gateway is AppPrivacyGateway) {
      _privacyLocked = (gateway as AppPrivacyGateway).privacyStatus.locked;
    }
    if (gateway is SessionVaultGateway) {
      await (gateway as SessionVaultGateway).initialize(_endpoint);
    }
  });

  Future<void> enterPreview() => _run((epoch) async {
    if (!previewAvailable) throw const GatewayFailure('合成演示只在显式开发构建中可用。');
    _session = const VaultSession(SessionStage.preview);
    _locations
      ..clear()
      ..add(const VaultLocation(VaultPage.environments));
    await _pull(epoch);
  });

  bool _allowed(VaultLocation next) {
    if (privacyObscured) return false;
    if (next.page == VaultPage.entry) {
      return _session.stage == SessionStage.signedOut;
    }
    if ({VaultPage.login, VaultPage.registration}.contains(next.page)) {
      return _session.stage == SessionStage.signedOut &&
          serverVerified &&
          (next.page != VaultPage.registration || registrationAvailable);
    }
    if (next.page == VaultPage.recovery) {
      return _session.stage == SessionStage.signedOut && serverVerified ||
          restrictedRecovery;
    }
    if ({
      VaultPage.authorization,
      VaultPage.initialization,
    }.contains(next.page)) {
      return _session.stage == SessionStage.deviceAuthorization;
    }
    if (!canEnterVault) return false;
    if ({
      VaultPage.environmentDetail,
      VaultPage.variableEditor,
    }.contains(next.page)) {
      return environments.any((e) => e.id == next.environmentId);
    }
    if (next.page == VaultPage.deviceDetail) {
      return next.requestId != null
          ? pendingAuthorizationRequests.any((r) => r.id == next.requestId)
          : devices.any((d) => d.id == next.deviceId);
    }
    return true;
  }

  bool navigate(
    VaultPage page, {
    String? environmentId,
    String? deviceId,
    String? requestId,
  }) {
    final next = VaultLocation(
      page,
      environmentId: environmentId,
      deviceId: deviceId,
      requestId: requestId,
    );
    if (_disposed || !_allowed(next)) return false;
    if (requestId != null && requestId == _activePrompt) _activePrompt = null;
    _locations.add(next);
    _notify();
    return true;
  }

  bool selectTab(VaultPage page) {
    if (!canEnterVault ||
        !{
          VaultPage.environments,
          VaultPage.devices,
          VaultPage.settings,
        }.contains(page)) {
      return false;
    }
    _locations
      ..clear()
      ..add(VaultLocation(page));
    _notify();
    return true;
  }

  bool goBack() {
    if (privacyObscured || !canGoBack) return false;
    _locations.removeLast();
    while (_locations.length > 1 && !_allowed(_locations.last)) {
      _locations.removeLast();
    }
    if (!_allowed(_locations.last)) {
      _locations
        ..clear()
        ..add(
          VaultLocation(switch (_session.stage) {
            SessionStage.deviceAuthorization => VaultPage.authorization,
            SessionStage.restrictedRecovery => VaultPage.recovery,
            SessionStage.trusted ||
            SessionStage.preview => VaultPage.environments,
            SessionStage.signedOut => VaultPage.entry,
          }),
        );
    }
    _notify();
    return true;
  }

  bool openDeepLink(Uri uri) {
    if (uri.scheme != 'harmonia' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    final parts = [if (uri.host.isNotEmpty) uri.host, ...uri.pathSegments];
    if (parts.isEmpty) return false;
    if (parts.length == 2 && parts.first == 'environment') {
      return navigate(VaultPage.environmentDetail, environmentId: parts.last);
    }
    if (parts.length == 2 && parts.first == 'device') {
      return navigate(VaultPage.deviceDetail, deviceId: parts.last);
    }
    if (parts.length == 1 && parts.first == 'settings') {
      return navigate(VaultPage.settings);
    }
    return false;
  }

  Future<void> _pull(int epoch) async {
    if (!canEnterVault) throw const GatewayFailure('完成设备授权后才能读取保险库。');
    final pulled = await gateway.pull();
    if (epoch != _epoch || !canEnterVault) return;
    if (pulled.checkpoint < _snapshot.checkpoint) {
      throw const GatewayFailure('返回的检查点倒退，已拒绝更新。');
    }
    _snapshot = pulled;
    _phase = previewMode ? ConnectionPhase.preview : ConnectionPhase.online;
    _locations.removeWhere((r) => !_allowed(r));
    if (_locations.isEmpty) {
      _locations.add(const VaultLocation(VaultPage.environments));
    }
  }

  Future<void> reload() => _run((epoch) async {
    _phase = ConnectionPhase.syncing;
    try {
      await _pull(epoch);
    } on GatewayFailure {
      _phase = ConnectionPhase.blocked;
      rethrow;
    }
  });
  Future<void> unlockSavedDevice() => _run((epoch) async {
    if (!supports('restoreSession')) {
      throw const GatewayFailure('可信设备视图恢复尚未接通，不能靠登录或公钥进入保险库。');
    }
    final session = await (gateway as SessionVaultGateway).restoreSession();
    if (epoch != _epoch) return;
    _applySession(session);
    if (canEnterVault) await _pull(epoch);
  });
  Future<void> signIn(String email, String password) => _run((epoch) async {
    if (!serverVerified || !supports('loginAccount')) {
      throw const GatewayFailure('账号登录适配尚未验收，未发送邮箱或密码。');
    }
    final result = await (gateway as SessionVaultGateway).loginAccount(
      email,
      password,
    );
    if (epoch != _epoch) return;
    if (!result.authenticated || result.trustedDevice) {
      throw const GatewayFailure('账号登录结果不符合独立设备信任边界。');
    }
    _applySession(const VaultSession(SessionStage.deviceAuthorization));
  });
  Future<void> registerAccount(String email, String password) =>
      _run((epoch) async {
        if (!serverVerified ||
            !registrationAvailable ||
            !supports('registerAccount')) {
          throw const GatewayFailure('注册界面尚未接通真实业务，未发送邮箱或密码。');
        }
        await (gateway as SessionVaultGateway).registerAccount(email, password);
      });

  String _environmentName(String name) {
    final clean = name.trim();
    if (clean.isEmpty || clean.runes.length > 120 || clean.contains('\u0000')) {
      throw const GatewayFailure('环境名称需为 1–120 个 Unicode 字符，不含空字符。');
    }
    return clean;
  }

  void _validateVariable(String name, String value) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(name) ||
        name.toUpperCase().startsWith('__HARMONIA_')) {
      throw const GatewayFailure('变量名最多128个ASCII字符，不能使用保留前缀 __HARMONIA_。');
    }
    if (value.contains('\u0000') || utf8.encode(value).length > 65536) {
      throw const GatewayFailure(
        '变量值不能含空字符或超过65536个UTF-8字节；真实手机请求还受完整JSON大小限制。',
      );
    }
  }

  Future<void> _mutate(PreviewMutation mutation) =>
      _run((epoch) => _submitMutation(mutation, epoch));
  Future<void> _submitMutation(PreviewMutation mutation, int epoch) async {
    if (!canEnterVault ||
        !supports(mutation.operation.name) ||
        !previewMode && _phase != ConnectionPhase.online) {
      throw const GatewayFailure('当前设备或连接状态不允许共享修改。离线仅可读已验配置。');
    }
    await gateway.submit(mutation);
    await _pull(epoch);
  }

  Future<void> createEnvironment(String name) => _run((epoch) async {
    await _submitMutation(
      PreviewMutation(
        PreviewOperation.createEnvironment,
        name: _environmentName(name),
      ),
      epoch,
    );
  });
  Future<void> renameEnvironment(String id, String name) => _run((epoch) async {
    await _submitMutation(
      PreviewMutation(
        PreviewOperation.renameEnvironment,
        environmentId: id,
        name: _environmentName(name),
      ),
      epoch,
    );
  });
  Future<void> deleteEnvironment(String id) => _mutate(
    PreviewMutation(PreviewOperation.deleteEnvironment, environmentId: id),
  );
  Future<void> setVariable(
    String environmentId,
    String name,
    String value,
  ) async {
    try {
      _validateVariable(name, value);
    } on GatewayFailure catch (failure) {
      _error = failure.message;
      _notify();
      return;
    }
    await _mutate(
      PreviewMutation(
        PreviewOperation.setVariable,
        environmentId: environmentId,
        name: name,
        value: value,
      ),
    );
  }

  Future<void> deleteVariable(String environmentId, String name) => _mutate(
    PreviewMutation(
      PreviewOperation.deleteVariable,
      environmentId: environmentId,
      name: name,
    ),
  );

  Future<void> setEndpoint(String value) => _run((epoch) async {
    if (_session.stage != SessionStage.signedOut) {
      throw const GatewayFailure('先退出当前会话，再切换服务地址。');
    }
    final candidate = Uri.tryParse(value.trim());
    if (candidate == null ||
        candidate.scheme != 'https' ||
        candidate.host.isEmpty ||
        candidate.userInfo.isNotEmpty ||
        candidate.hasQuery ||
        candidate.hasFragment) {
      throw const GatewayFailure('请输入 HTTPS 服务地址，不得包含凭据、查询参数或片段。');
    }
    _endpoint = candidate.toString();
    _instance = null;
    _phase = ConnectionPhase.blocked;
    if (gateway is SessionVaultGateway) {
      await (gateway as SessionVaultGateway).initialize(_endpoint);
    }
  });
  Future<void> approveDevice(ApprovalDraft draft) => _run((epoch) async {
    if (!canEnterVault || !supports('approveDevice')) {
      throw const GatewayFailure('配对审批界面尚未接通已验原生能力，未批准设备。');
    }
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$')
            .hasMatch(draft.pairingId) ||
        !RegExp(r'^[0-9]{8}$').hasMatch(draft.code) ||
        draft.roles.isEmpty) {
      throw const GatewayFailure('需独立 PairID、8位数字秘密短码及明确环境权限。');
    }
    await (gateway as SessionVaultGateway).approve(draft);
  });
  Future<void> revokeDevice(String id) => _run((epoch) async {
    if (!canEnterVault || !supports('revokeDevice')) {
      throw const GatewayFailure('设备撤销适配尚未接通，未执行撤销。');
    }
    await (gateway as SessionVaultGateway).revoke(id);
  });
  Future<void> beginRecovery() => _run((epoch) async {
    throw const GatewayFailure('连续恢复界面尚未验收，当前入口不可用。');
  });
  Future<void> rotateRecovery(String completeReentry) => _run((epoch) async {
    throw const GatewayFailure('新码轮换界面尚未验收，未提交轮换。');
  });
  Future<void> queryRecoveryStatus() => _run((epoch) async {
    throw const GatewayFailure('恢复状态适配未开放，不能确认服务器结果。');
  });

  Future<void> logout() {
    if (_disposed) return Future<void>.value();
    if (_cleanupInFlight != null) return _cleanupInFlight!;
    _nativeCleanupPending = true;
    final token = ++_cleanupSerial;
    _activeCleanup = token;
    _resetLocalSession();
    _activeOperation = null;
    _busy = false;
    _error = null;
    _notify();
    final epoch = _epoch;
    final future = _performLogout(token, epoch);
    _cleanupInFlight = future;
    return future;
  }

  Future<void> _performLogout(int token, int epoch) async {
    await Future<void>.value();
    try {
      if (gateway is SessionVaultGateway) {
        await (gateway as SessionVaultGateway).logout();
      }
      if (!_disposed && _activeCleanup == token && epoch == _epoch) {
        _nativeCleanupPending = false;
      }
    } on GatewayFailure catch (failure) {
      if (!_disposed && _activeCleanup == token && epoch == _epoch) {
        _error = failure.message;
      }
    } catch (_) {
      if (!_disposed && _activeCleanup == token && epoch == _epoch) {
        _error = '本机视图已关闭，原生退出清理未确认。请查询原操作。';
      }
    } finally {
      if (_activeCleanup == token) {
        _activeCleanup = null;
        _cleanupInFlight = null;
      }
      _notify();
    }
  }

  void onLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _privacyMask = true;
      _notify();
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _privacyMask = true;
      final status = gateway is AppPrivacyGateway
          ? (gateway as AppPrivacyGateway).privacyStatus
          : null;
      if (status != null && status.enabled && !status.systemPromptInFlight) {
        _privacyLocked = true;
      }
      setForeground(false);
      _notify();
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _privacyMask = false;
      setForeground(true);
      _notify();
    }
  }

  Future<void> unlockPrivacy() async {
    if (_privacyUnlocking ||
        !privacyLockAvailable ||
        _disposed ||
        _nativeCleanupPending) {
      return;
    }
    _privacyUnlocking = true;
    _error = null;
    _notify();
    try {
      await (gateway as AppPrivacyGateway).unlockPrivacy();
      if (!_disposed) {
        _privacyLocked = (gateway as AppPrivacyGateway).privacyStatus.locked;
      }
    } on GatewayFailure catch (failure) {
      _error = failure.message;
    } catch (_) {
      _error = '解锁未完成。取消、失败或暂时锁定不会降级到 PIN。';
    } finally {
      _privacyUnlocking = false;
      _notify();
    }
  }

  void setForeground(bool value) {
    _foreground = value;
    if (value) {
      unawaited(refreshAuthorizationRequests());
    }
  }

  Future<void> refreshAuthorizationRequests() async {
    if (!_foreground ||
        !canEnterVault ||
        !authorizationRequestsAvailable ||
        _disposed ||
        _requestsBusy) {
      return;
    }
    _requestsBusy = true;
    final epoch = _epoch;
    try {
      final received = await (gateway as SessionVaultGateway)
          .authorizationRequests();
      if (epoch != _epoch || !canEnterVault) return;
      for (final r in received) {
        if (r.accountId != _session.accountId ||
            r.accountGeneration != _session.accountGeneration ||
            r.id.isEmpty ||
            r.sequence <= 0 ||
            r.sequence <= (_requestVersions[r.id] ?? 0)) {
          continue;
        }
        _requestVersions[r.id] = r.sequence;
        if (r.status == AuthorizationRequestStatus.pending &&
            r.expiresAt.isAfter(_now())) {
          _requests[r.id] = r;
          if (!_prompted.contains(r.id) && !_promptQueue.contains(r.id)) {
            _promptQueue.add(r.id);
          }
        } else {
          _requests.remove(r.id);
          _promptQueue.remove(r.id);
        }
      }
      purgeExpiredAuthorizationRequests();
      _sanitizeLocations();
      _notify();
    } catch (_) {
      // 前台通知失败不能伪造待批准事件，也不能改变设备信任。
    } finally {
      _requestsBusy = false;
    }
  }

  void _sanitizeLocations() {
    _locations.removeWhere((r) => !_allowed(r));
    if (_locations.isEmpty) {
      _locations.add(
        VaultLocation(canEnterVault ? VaultPage.devices : VaultPage.entry),
      );
    }
  }

  void purgeExpiredAuthorizationRequests() {
    final expired = _requests.values
        .where((r) => !_requestVisible(r))
        .map((r) => r.id)
        .toList();
    for (final id in expired) {
      _requests.remove(id);
      _promptQueue.remove(id);
    }
    if (_activePrompt != null && !_requests.containsKey(_activePrompt)) {
      _activePrompt = null;
    }
    _sanitizeLocations();
    _notify();
  }

  void dismissAuthorizationPrompt() {
    _activePrompt = null;
    _notify();
  }

  AuthorizationRequest? takeAuthorizationPrompt() {
    if (!_foreground || !canEnterVault || !authorizationRequestsAvailable) {
      return null;
    }
    if (_activePrompt != null && authorizationRequest(_activePrompt!) != null) {
      return null;
    }
    _activePrompt = null;
    while (_promptQueue.isNotEmpty) {
      final id = _promptQueue.removeAt(0), request = _requests[id];
      if (request != null && _requestVisible(request) && _prompted.add(id)) {
        _activePrompt = id;
        return request;
      }
    }
    return null;
  }

  AuthorizationRequest? authorizationRequest(String id) {
    final request = _requests[id];
    return request != null && _requestVisible(request) ? request : null;
  }

  @override
  void dispose() {
    _disposed = true;
    _resetLocalSession();
    super.dispose();
  }
}
