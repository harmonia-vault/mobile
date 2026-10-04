import 'dart:async';
import 'dart:convert';

import 'recovery/recovery_presentation.dart';
import 'management/management_presentation.dart';
import 'management/management_gateway.dart';
import 'recovery/recovery_gateway.dart';
import 'recovery/recovery_coordinator.dart';

import 'package:flutter/foundation.dart';

import 'native/native_pin_adapter.dart';

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
  const GatewayFailure(
    this.message, {
    this.suspendVault = false,
    this.invalidateSession = false,
  });
  final String message;
  final bool suspendVault, invalidateSession;
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

/// 公开实例已验证后同步绑定地址；不是设备信任或服务器认证凭据。
abstract interface class ServerScopeGateway {
  void bindVerifiedServer(String endpoint);
}

@immutable
class AccountRegistration {
  const AccountRegistration({
    required this.accountId,
    required this.accountGeneration,
    required this.verificationRequired,
  });
  final String accountId, accountGeneration;
  final bool verificationRequired;
}

@immutable
class PendingVaultOperation {
  const PendingVaultOperation({
    required this.id,
    required this.operation,
    required this.environmentId,
    required this.state,
    required this.sequence,
    required this.applied,
  });
  final String id, operation, environmentId, state;
  final int sequence;
  final bool applied;
  bool get canRetry => state == 'unknown' || state == 'accepted-not-applied';
}

abstract interface class BusinessPendingGateway {
  Future<List<PendingVaultOperation>> businessPendingInfo();
  Future<PendingVaultOperation> retryBusinessOperation(String id);
}

@immutable
class DeviceApprovalProgress {
  const DeviceApprovalProgress({
    required this.state,
    this.pairingId = '',
    this.sequence = 0,
  });
  final String state, pairingId;
  final int sequence;
  bool get canRetry => {'prepared', 'unknown', 'approved'}.contains(state);
  bool get canCancel => state == 'prepared';
}

abstract interface class ApprovalContinuationGateway {
  DeviceApprovalProgress get approvalProgress;
  Future<DeviceApprovalProgress> queryApproval();
  Future<DeviceApprovalProgress> retryApproval(String originalPairingId);
  Future<void> cancelApproval(String originalPairingId);
}

abstract interface class EmailProofGateway {
  Future<void> verifyEmail(
    AccountRegistration registration,
    String challengeId,
    String token,
  );
}

abstract interface class InitializationGateway {
  Future<String> beginInitialization(
    String email,
    String password,
    String name,
  );
  Future<VaultSession> completeInitialization(String fullCodeReentry);
  Future<String> queryInitialization();
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
  emailProof,
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
  }) : businessPending = const [];

  /// 同次已验证恢复的公开续办元数据；不包含签包、token或业务值。
  VaultSession.withBusinessPending(
    VaultSession verifiedSession,
    Iterable<PendingVaultOperation> pending,
  ) : stage = verifiedSession.stage,
      accountId = verifiedSession.accountId,
      accountGeneration = verifiedSession.accountGeneration,
      businessPending = List.unmodifiable(pending);

  final SessionStage stage;
  final String accountId, accountGeneration;
  final List<PendingVaultOperation> businessPending;
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
  Future<AccountRegistration> registerAccount(String email, String password);
  Future<VaultSession> restoreSession();
  Future<void> logout();
  Future<List<AuthorizationRequest>> authorizationRequests();
  Future<void> approve(ApprovalDraft draft);
  Future<void> revoke(String deviceId);
}

class VaultController extends ChangeNotifier
    implements RecoveryActions, ManagementActions {
  VaultController({
    required this.gateway,
    this.allowPreview = false,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  ManagementOperation _managementOperation = const ManagementOperation(
    phase: ManagementPhase.idle,
  );
  List<ManagedDeviceAccess> _managedDevices = const [];
  String _managedEnvironment = '',
      _managementStatus = '先检查本机原管理操作，再读取当前Admin环境设备。';
  String? _managementError;
  bool _managementInspected = false, _managementRunning = false;
  bool get _hasManagementContinuation => _managementOperation.unresolved;
  void _clearManagementList() {
    _managedDevices = const [];
    _managedEnvironment = '';
  }

  void _resetManagement() {
    if (gateway is DeviceManagementGateway) {
      (gateway as DeviceManagementGateway).retireManagementResults();
    }
    _clearManagementList();
    _managementInspected = false;
    _managementRunning = false;
    _managementOperation = const ManagementOperation(
      phase: ManagementPhase.idle,
    );
    _managementError = null;
    _managementStatus = '先检查本机原管理操作，再读取当前Admin环境设备。';
  }

  bool _managementAdmin(String id) => _snapshot.environments.any(
    (e) => e.id == id && e.role == AccessRole.admin,
  );
  @override
  ManagementPresentation get management {
    final caps = gateway is DeviceManagementGateway
        ? (gateway as DeviceManagementGateway).managementCapabilities
        : const <String>{};
    final available =
        serverVerified &&
        !_disposed &&
        !_nativeCleanupPending &&
        !_busy &&
        !privacyObscured &&
        _foreground &&
        !previewMode;
    final actions = <ManagementAction>{};
    if (available) {
      if (caps.contains('managementInfo')) {
        actions.add(ManagementAction.inspect);
      }
      if (canEnterVault &&
          !_hasManagementContinuation &&
          caps.contains('managementDevices') &&
          _snapshot.environments.any((e) => e.role == AccessRole.admin)) {
        actions.add(ManagementAction.loadDevices);
      }
      if (canEnterVault &&
          _phase == ConnectionPhase.online &&
          _managementInspected &&
          !_hasManagementContinuation &&
          _managedEnvironment.isNotEmpty &&
          _managementAdmin(_managedEnvironment)) {
        if (caps.contains('prepareDeviceGrant')) {
          actions.add(ManagementAction.prepareGrant);
        }
        if (caps.contains('prepareOtherDeviceRevocation') &&
            _managedDevices.any((d) => !d.current)) {
          actions.add(ManagementAction.prepareRevocation);
        }
      }
      if (_hasManagementContinuation &&
          _managementOperation.id.isNotEmpty &&
          caps.contains('retryManagement')) {
        actions.add(ManagementAction.submitOriginal);
      }
      if (_managementOperation.phase == ManagementPhase.prepared &&
          !_managementOperation.attempted &&
          caps.contains('cancelManagement')) {
        actions.add(ManagementAction.cancelOriginal);
      }
    }
    return ManagementPresentation(
      busy: _busy,
      environmentId: _managedEnvironment,
      status: _managementStatus,
      error: _managementError,
      operation: _managementOperation,
      devices: !privacyObscured && _foreground && !_nativeCleanupPending
          ? _managedDevices
          : const [],
      actions: actions,
    );
  }

  Future<void> _managementAction(
    ManagementAction action,
    Future<void> Function(int epoch) body,
  ) async {
    if (!management.allows(action)) {
      _error = '此管理动作尚无当前权限、原状态或逐项实测能力。';
      _notify();
      return;
    }
    await _run((epoch) async {
      _managementError = null;
      _managementRunning = true;
      try {
        await body(epoch);
      } on GatewayFailure catch (e) {
        if (epoch == _epoch) _managementError = e.message;
        rethrow;
      } finally {
        if (epoch == _epoch && gateway is DeviceManagementGateway) {
          _managementRunning = false;
          _managementOperation =
              (gateway as DeviceManagementGateway).managementOperation;
          if (_hasManagementContinuation) {
            _suspendVault();
            _clearManagementList();
            _managementStatus = '仅续办原管理ID；prepared尚未提交，未知或accepted不代表本机已完成。';
          }
        }
      }
    });
  }

  @override
  Future<void> inspectDeviceManagement() =>
      _managementAction(ManagementAction.inspect, (epoch) async {
        final result = await (gateway as DeviceManagementGateway)
            .inspectManagement();
        if (epoch != _epoch) return;
        _managementOperation = result;
        _managementInspected = true;
        _managementStatus = result.phase == ManagementPhase.idle
            ? '本机没有未决管理原包；设备列表仍须独立读取。'
            : '已读取本机原管理状态，未自动提交或改权。';
      });
  @override
  Future<void> loadManagedDevices(String environmentId) => _managementAction(
    ManagementAction.loadDevices,
    (epoch) async {
      if (!_managementAdmin(environmentId)) {
        throw const GatewayFailure('仅当前已验Admin环境可读取管理设备。');
      }
      _clearManagementList();
      // 先查全局原管理槽，不能绕冷pending新建另一ID。
      final pending = await (gateway as DeviceManagementGateway)
          .inspectManagement();
      if (epoch != _epoch) return;
      _managementOperation = pending;
      _managementInspected = true;
      if (pending.unresolved) return;
      final rows = await (gateway as DeviceManagementGateway).managementDevices(
        environmentId,
      );
      if (epoch != _epoch) return;
      await _pull(epoch);
      if (epoch != _epoch) return;
      if (!canEnterVault || !_managementAdmin(environmentId)) {
        throw const GatewayFailure('当前环境管理权已改变，未显示旧管理列表。', suspendVault: true);
      }
      _managedDevices = List.unmodifiable(rows);
      _managedEnvironment = environmentId;
      _managementStatus = '显示成熟Go验证的设备ID与授权元数据；准备变更后仍需明确提交。';
    },
  );
  void _validateManagedTarget(
    String environmentId,
    String deviceId, {
    bool other = false,
  }) {
    final rows = _managedDevices
        .where(
          (d) => d.deviceId == deviceId && d.environmentId == environmentId,
        )
        .toList();
    if (environmentId != _managedEnvironment ||
        !_managementAdmin(environmentId) ||
        rows.length != 1 ||
        other && rows.single.current) {
      throw const GatewayFailure('须从当前已验管理列表明确选择目标；其它设备撤销不适用于本机。');
    }
  }

  @override
  Future<void> prepareManagedDeviceGrant({
    required String environmentId,
    required String subjectDeviceId,
    required ManagedRole role,
    required ManagementExpiry expiry,
  }) => _managementAction(ManagementAction.prepareGrant, (epoch) async {
    _validateManagedTarget(environmentId, subjectDeviceId);
    final result = await (gateway as DeviceManagementGateway)
        .prepareDeviceGrant(
          environmentId: environmentId,
          subjectDeviceId: subjectDeviceId,
          role: role,
          expiry: expiry,
        );
    if (epoch != _epoch) return;
    _managementOperation = result;
    _retireSensitiveForm();
    _managementStatus = '原授权意图已密封；尚未提交。必须明确提交同一原操作。';
  });
  @override
  Future<void> prepareManagedDeviceRevocation({
    required String environmentId,
    required String subjectDeviceId,
    required bool destructiveConfirmed,
  }) => _managementAction(ManagementAction.prepareRevocation, (epoch) async {
    if (!destructiveConfirmed) throw const GatewayFailure('整台其它设备撤销需要明确破坏性确认。');
    _validateManagedTarget(environmentId, subjectDeviceId, other: true);
    final result = await (gateway as DeviceManagementGateway)
        .prepareOtherDeviceRevocation(
          environmentId: environmentId,
          subjectDeviceId: subjectDeviceId,
        );
    if (epoch != _epoch) return;
    _managementOperation = result;
    _retireSensitiveForm();
    _managementStatus = '其它设备撤销原包已密封；未声称服务器撤销生效，需明确提交。';
  });
  Future<void> _finishManagement(ManagementOperation result, int epoch) async {
    _managementOperation = result;
    _clearManagementList();
    _retireSensitiveForm();
    // 即使本机被自己降权，也只从正式恢复与Pull显示剩余权限。
    final session = await (gateway as SessionVaultGateway).restoreSession();
    if (epoch != _epoch) return;
    _applySession(session);
    await _pullRestoredSession(epoch);
    if (epoch != _epoch) return;
    _managementStatus = result.phase == ManagementPhase.cancelled
        ? '原未提交管理包已确认取消；当前视图已重新验证。'
        : '原管理操作已接受并本机应用；当前权限已重新拉取。';
  }

  @override
  Future<void> submitOriginalManagement() =>
      _managementAction(ManagementAction.submitOriginal, (epoch) async {
        final result = await (gateway as DeviceManagementGateway)
            .retryManagement(_managementOperation.id);
        if (epoch != _epoch) return;
        await _finishManagement(result, epoch);
      });
  @override
  Future<void> cancelOriginalManagement() =>
      _managementAction(ManagementAction.cancelOriginal, (epoch) async {
        final result = await (gateway as DeviceManagementGateway)
            .cancelManagement(_managementOperation.id);
        if (epoch != _epoch) return;
        await _finishManagement(result, epoch);
      });

  late final RecoveryCoordinator _recoveryFlow = RecoveryCoordinator(
    gateway is RecoveryGateway ? gateway as RecoveryGateway : null,
    now: _now,
    changed: _notify,
    onTrusted: _acceptRecoveredDevice,
  );
  final VaultGateway gateway;
  final bool allowPreview;
  final DateTime Function() _now;
  bool _privacyMask = false, _privacyLocked = false, _privacyUnlocking = false;
  bool _vaultSuspended = false;
  AccountRegistration? _registration;
  String? _initializationCode;
  String _initializationState = 'none';
  DeviceApprovalProgress _approvalProgress = const DeviceApprovalProgress(
    state: 'none',
  );
  List<PendingVaultOperation> _businessPending = const [];
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

  // 仅控制当前表单RAM寿命，不是认证成功或授权信号。
  Timer? _formRetentionTimer;
  bool _retainedForm = false;
  int _formLifetime = 0;
  @override
  String get sensitiveFormScope =>
      '$_epoch|$_formLifetime|${_session.accountId}|${_session.accountGeneration}|$_endpoint|${_session.stage.name}';
  @override
  bool get retainSensitiveForm =>
      _retainedForm &&
      _privacyMask &&
      _foreground &&
      !_privacyLocked &&
      !_vaultSuspended &&
      !_disposed &&
      !_nativeCleanupPending;
  void _retireSensitiveForm() {
    _formRetentionTimer?.cancel();
    _formRetentionTimer = null;
    _retainedForm = false;
    _formLifetime++;
  }

  void _boundFormRetention(Duration duration) {
    _formRetentionTimer?.cancel();
    _formRetentionTimer = Timer(duration, () {
      _retireSensitiveForm();
      _notify();
    });
  }

  bool _accessReduced(VaultSnapshot previous, VaultSnapshot next) {
    final selected = location.environmentId;
    final current = {for (final e in next.environments) e.id: e};
    for (final e in previous.environments) {
      // 当前环境编辑器只因自身失权退役；无关环境删除不丢其草稿。
      if (selected != null && e.id != selected) continue;
      final updated = current[e.id];
      if (updated == null || updated.role.index < e.role.index) return true;
    }
    return false;
  }

  bool get privacyObscured => _privacyMask || _privacyLocked;
  bool get privacyLocked => _privacyLocked;
  bool get privacyLockAvailable => gateway is AppPrivacyGateway;
  bool get serverVerified => _instance != null;
  AccountRegistration? get registration => _registration;
  String? get initializationCode => _initializationCode;
  String get initializationState => _initializationState;
  List<PendingVaultOperation> get businessPending => _businessPending;
  bool get vaultSuspended => _vaultSuspended;
  DeviceApprovalProgress get approvalProgress => _approvalProgress;
  bool get registrationAvailable =>
      _instance != null &&
      (_instance!.initialRegistrationAvailable || _instance!.allowRegistration);
  bool get emailVerificationRequired =>
      _instance?.emailVerificationRequired ?? false;
  bool get connectionAvailable => gateway is InstanceConnectionGateway;
  bool get previewMode => _session.stage == SessionStage.preview;
  bool get previewAvailable => allowPreview && gateway.synthetic;
  bool get canEnterVault =>
      !_vaultSuspended &&
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
  String get recoveryStatus => recovery.status;
  @override
  RecoveryPresentation get recovery => _recoveryFlow.presentation(
    available:
        serverVerified &&
        !_disposed &&
        !_nativeCleanupPending &&
        !privacyObscured &&
        _foreground &&
        !previewMode,
    busy: _busy,
  );
  @override
  String? get recoveryCodeForDisplay =>
      privacyObscured || !_foreground || _disposed
      ? null
      : _recoveryFlow.visibleCode;
  void _acceptRecoveredDevice(RecoveryTrusted source, String nativeOperation) {
    if (_disposed || !_foreground || _nativeCleanupPending) return;
    _applySession(source.session);
    _snapshot = VaultSnapshot(
      checkpoint: source.snapshot.checkpoint,
      environments: source.snapshot.environments,
      devices: [
        VaultDevice(
          id: source.deviceId,
          name: '本机',
          platform: 'Android',
          current: true,
          accessSummary: source.snapshot.environments
              .map((e) => '${e.name}：${e.role.label}')
              .join('；'),
          expiresLabel: '按原生已验授权生效',
        ),
      ],
    );
    _phase = nativeOperation == 'restoreDAGRecoveredDevice'
        ? ConnectionPhase.offline
        : ConnectionPhase.online;
  }

  Future<void> _recoveryAction(
    RecoveryAction action,
    Future<void> Function() body, {
    Uint8List? code,
  }) async {
    try {
      if (!recovery.allows(action)) {
        _error = recovery.unavailableReason(action);
        _notify();
        return;
      }
      await _run((epoch) async {
        await body();
        if (epoch == _epoch &&
            !_disposed &&
            !recovery.trustedDevice &&
            (recovery.ownerAvailable || recovery.operationId != null) &&
            _session.stage != SessionStage.restrictedRecovery) {
          _applySession(const VaultSession(SessionStage.restrictedRecovery));
        }
      });
    } finally {
      code?.fillRange(0, code.length, 0);
    }
  }

  @override
  Future<void> inspectRecovery() =>
      _recoveryAction(RecoveryAction.inspect, _recoveryFlow.inspect);
  @override
  Future<void> openRecovery({
    required String email,
    required String password,
    required Uint8List currentCode,
  }) => _recoveryAction(
    RecoveryAction.open,
    () => _recoveryFlow.open(email, password, currentCode),
    code: currentCode,
  );
  @override
  Future<void> prepareRecoveryCode() =>
      _recoveryAction(RecoveryAction.prepareCode, _recoveryFlow.prepare);
  @override
  void setRecoveryCodeVisible(bool visible) =>
      _recoveryFlow.hideCode(visible && !privacyObscured && _foreground);
  @override
  Future<void> sealRecoveryTransition(Uint8List completeReentry) =>
      _recoveryAction(
        RecoveryAction.sealTransition,
        () => _recoveryFlow.seal(completeReentry),
        code: completeReentry,
      );
  @override
  Future<void> submitRecoveryTransition() => _recoveryAction(
    RecoveryAction.submitTransition,
    _recoveryFlow.submitTransition,
  );
  @override
  Future<void> queryRecoveryOriginal(Uint8List completeCurrentCode) =>
      _recoveryAction(
        RecoveryAction.queryOriginal,
        () => _recoveryFlow.query(completeCurrentCode),
        code: completeCurrentCode,
      );
  @override
  Future<void> loadRecoveryChoices() =>
      _recoveryAction(RecoveryAction.loadChoices, _recoveryFlow.loadChoices);
  @override
  Future<void> sealRecoveryEnrollment(List<RecoverySelection> selections) =>
      _recoveryAction(
        RecoveryAction.sealEnrollment,
        () => _recoveryFlow.sealEnrollment(List.unmodifiable(selections)),
      );
  @override
  Future<void> submitRecoveryEnrollment() => _recoveryAction(
    RecoveryAction.submitEnrollment,
    _recoveryFlow.submitEnrollment,
  );
  @override
  Future<void> verifyRecoveredDevice() => _recoveryAction(
    RecoveryAction.verifyDevice,
    () => _recoveryFlow.device('applyDAGRecoveredDevice'),
  );
  @override
  Future<void> restoreRecoveredDevice() => _recoveryAction(
    RecoveryAction.restoreDevice,
    () => _recoveryFlow.device('restoreDAGRecoveredDevice'),
  );
  @override
  Future<void> pullRecoveredDevice() => _recoveryAction(
    RecoveryAction.pullDevice,
    () => _recoveryFlow.device('pullDAGRecoveredDevice'),
  );
  @override
  Future<void> cancelRecoveryLocally() async {
    if (_disposed) return;
    _retireSensitiveForm();
    _epoch++;
    _activeOperation = null;
    _busy = false;
    _suspendVault();
    await _recoveryFlow.cancel();
  }

  @override
  Future<void> queryRecoveryClosure(Uint8List completeCurrentCode) =>
      _recoveryAction(
        RecoveryAction.queryClosure,
        () async {},
        code: completeCurrentCode,
      );
  @override
  Future<void> closeRecoveryOriginal(
    Uint8List completeCurrentCode, {
    required bool destructiveConfirmed,
  }) => _recoveryAction(
    RecoveryAction.closeOriginal,
    () async {},
    code: completeCurrentCode,
  );
  @override
  Future<void> restartRecoveryAfterClosure(Uint8List completeCurrentCode) =>
      _recoveryAction(
        RecoveryAction.restartAfterClosure,
        () async {},
        code: completeCurrentCode,
      );

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

  LocalProtectionStatus? get localProtectionStatus =>
      gateway is LocalProtectionGateway
      ? (gateway as LocalProtectionGateway).localProtectionStatus
      : null;

  Future<void> refreshLocalProtection() => _run((epoch) async {
    if (gateway is! LocalProtectionGateway) return;
    try {
      await (gateway as LocalProtectionGateway).refreshLocalProtection();
    } catch (_) {
      _suspendVault();
      rethrow;
    }
    final status = localProtectionStatus;
    if (status?.upgradeRequired == true ||
        status?.mode == LocalProtectionMode.blocked) {
      _suspendVault();
    }
  });

  Future<void> setupLocalPIN() => _run((epoch) async {
    if (gateway is! LocalProtectionGateway ||
        _session.stage != SessionStage.signedOut) {
      throw const GatewayFailure('须先完成本机退出，才能设置新的PIN设备。');
    }
    await (gateway as LocalProtectionGateway).setupLocalPIN();
  });

  Future<void> forgetLocalPIN() => _run((epoch) async {
    if (gateway is! LocalProtectionGateway) {
      throw const GatewayFailure('本平台未接本机PIN清理。');
    }
    // 即使清理或确认中断，也先关本机明文视图；不能让失败清理继续暴露缓存。
    _suspendVault();
    _notify();
    await (gateway as LocalProtectionGateway).forgetLocalPIN();
    if ((gateway as LocalProtectionGateway)
            .localProtectionStatus
            ?.deviceExists ==
        false) {
      _resetLocalSession();
    }
  });

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
      if (epoch == _epoch) {
        if (failure.invalidateSession) _resetLocalSession();
        if (failure.suspendVault) {
          _retireSensitiveForm();
          _vaultSuspended = true;
          _snapshot = VaultSnapshot(
            checkpoint: 0,
            environments: const [],
            devices: const [],
          );
          _phase = ConnectionPhase.blocked;
        }
        if (!failure.invalidateSession &&
            gateway is ApprovalContinuationGateway) {
          _approvalProgress =
              (gateway as ApprovalContinuationGateway).approvalProgress;
          if (_approvalProgress.state != 'none' &&
              _approvalProgress.state != 'complete') {
            _suspendVault();
          }
        }
        _error = failure.message;
      }
    } catch (_) {
      if (epoch == _epoch) _error = '操作未完成。先查询原操作；未确认任何云端变更。';
    } finally {
      if (_activeOperation == token) {
        _busy = false;
        _activeOperation = null;
        if (_retainedForm && _privacyMask) {
          // 原生结果先于resumed时，与前台等待相同的五秒上限。
          _boundFormRetention(const Duration(seconds: 5));
        }
      }
      _notify();
    }
  }

  void _suspendVault() {
    _retireSensitiveForm();
    _vaultSuspended = true;
    _snapshot = VaultSnapshot(
      checkpoint: 0,
      environments: const [],
      devices: const [],
    );
    _phase = ConnectionPhase.blocked;
  }

  void _resetLocalSession() {
    _resetManagement();
    _recoveryFlow.invalidate(reset: true);
    _retireSensitiveForm();
    _epoch++;
    _vaultSuspended = false;
    _registration = null;
    _initializationCode = null;
    _initializationState = 'none';
    _approvalProgress = const DeviceApprovalProgress(state: 'none');
    _businessPending = const [];
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
    _retireSensitiveForm();
    if (session.stage == SessionStage.preview ||
        session.stage == SessionStage.trusted &&
            (session.accountId.isEmpty || session.accountGeneration.isEmpty)) {
      throw const GatewayFailure('设备信任结果缺少已核验的账号范围，已拒绝进入保险库。');
    }
    if (session.accountId != _session.accountId ||
        session.accountGeneration != _session.accountGeneration) {
      _clearManagementList();
      _requests.clear();
      _requestVersions.clear();
      _prompted.clear();
      _promptQueue.clear();
      _activePrompt = null;
    }
    // 先清旧账号范围，随后只采用本次可信恢复附带的不可变列表。
    _businessPending = const [];
    _session = session;
    if (session.stage == SessionStage.trusted) {
      _businessPending = List.unmodifiable(session.businessPending);
    }
    _vaultSuspended = _hasBusinessContinuation;
    if (_vaultSuspended) _phase = ConnectionPhase.blocked;
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
    if (gateway is ServerScopeGateway) {
      (gateway as ServerScopeGateway).bindVerifiedServer(candidate.toString());
    }
    _retireSensitiveForm();
    _endpoint = candidate.toString();
    _instance = verified;
    if (gateway is LocalProtectionGateway) {
      await (gateway as LocalProtectionGateway).refreshLocalProtection();
    }
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
    _retireSensitiveForm();
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
    if (gateway is LocalProtectionGateway) {
      await (gateway as LocalProtectionGateway).refreshLocalProtection();
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
    if (next.page == VaultPage.emailProof) {
      return _session.stage == SessionStage.signedOut &&
          serverVerified &&
          _registration?.verificationRequired == true;
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
    if (_hasManagementContinuation && next.page == VaultPage.devices) {
      return true;
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

  // 原生认证结果可能先于Flutter resumed到达。仅等已观察的前台恢复，
  // 不清隐私遮罩、不改变trust，后台/退出/销毁/旧操作一律停止。
  Future<void> _awaitVaultForeground(int epoch) async {
    if (!_privacyMask) return;
    final operation = _activeOperation;
    final deadline = Stopwatch()..start();
    while (_privacyMask) {
      if (_disposed ||
          epoch != _epoch ||
          operation == null ||
          operation != _activeOperation ||
          !_foreground ||
          _privacyLocked ||
          _vaultSuspended ||
          !(_session.stage == SessionStage.trusted || previewMode) ||
          deadline.elapsed >= const Duration(seconds: 5)) {
        throw const GatewayFailure('应用尚未恢复到前台，已停止本次读取。', suspendVault: true);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (_disposed ||
        epoch != _epoch ||
        operation != _activeOperation ||
        !_foreground ||
        !canEnterVault) {
      throw const GatewayFailure('应用尚未恢复到前台，已停止本次读取。', suspendVault: true);
    }
  }

  Future<void> _pull(int epoch) async {
    await _awaitVaultForeground(epoch);
    if (!canEnterVault) throw const GatewayFailure('完成设备授权后才能读取保险库。');
    final pulled = await gateway.pull();
    if (_disposed || epoch != _epoch) return;
    await _awaitVaultForeground(epoch);
    if (_disposed || epoch != _epoch || !canEnterVault) return;
    if (pulled.checkpoint < _snapshot.checkpoint) {
      throw const GatewayFailure('返回的检查点倒退，已拒绝更新。');
    }
    if (_accessReduced(_snapshot, pulled)) {
      // 同账号的撤销/降权/环境消失同样终止旧表单，不能只检查trusted。
      _retireSensitiveForm();
      _clearManagementList();
    }
    _snapshot = pulled;
    _phase = previewMode ? ConnectionPhase.preview : ConnectionPhase.online;
    _locations.removeWhere((r) => !_allowed(r));
    if (_locations.isEmpty) {
      _locations.add(const VaultLocation(VaultPage.environments));
    }
  }

  bool get _hasBusinessContinuation =>
      _hasManagementContinuation ||
      _session.stage == SessionStage.trusted &&
          _businessPending.any((item) => item.canRetry);

  // 自动恢复后的读取不能隐藏原ID入口；通用_pull仍保留全部原门槛。
  Future<void> _pullRestoredSession(int epoch) async {
    if (_hasBusinessContinuation) {
      _suspendVault();
      return;
    }
    await _pull(epoch);
  }

  Future<void> reload() => _run((epoch) async {
    if (_hasBusinessContinuation) {
      _suspendVault();
      return;
    }
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
    if (_session.stage == SessionStage.trusted || previewMode) {
      await _pullRestoredSession(epoch);
    }
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
        final registered = await (gateway as SessionVaultGateway)
            .registerAccount(email, password);
        if (epoch != _epoch) return;
        _registration = registered;
        if (registered.verificationRequired) {
          _locations.add(const VaultLocation(VaultPage.emailProof));
          return;
        }
        _applySession(const VaultSession(SessionStage.deviceAuthorization));
        _locations.add(const VaultLocation(VaultPage.initialization));
      });

  Future<void> verifyRegistrationEmail(String challengeId, String token) =>
      _run((epoch) async {
        final registered = _registration;
        if (!serverVerified ||
            registered == null ||
            !registered.verificationRequired ||
            !supports('verifyEmail') ||
            gateway is! EmailProofGateway) {
          throw const GatewayFailure('邮件证明适配尚未验收，未发送证明。');
        }
        if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$')
                .hasMatch(challengeId) ||
            token.isEmpty ||
            utf8.encode(token).length > 16384) {
          throw const GatewayFailure('请输入邮件中的挑战 ID 和一次证明 token。');
        }
        await (gateway as EmailProofGateway).verifyEmail(
          registered,
          challengeId,
          token,
        );
        if (epoch != _epoch) return;
        _registration = AccountRegistration(
          accountId: registered.accountId,
          accountGeneration: registered.accountGeneration,
          verificationRequired: false,
        );
        _applySession(const VaultSession(SessionStage.deviceAuthorization));
        _locations.add(const VaultLocation(VaultPage.initialization));
      });

  Future<void> beginInitialization(
    String email,
    String password,
    String name,
  ) => _run((epoch) async {
    if (_session.stage != SessionStage.deviceAuthorization ||
        !supports('beginInitialization') ||
        gateway is! InitializationGateway) {
      throw const GatewayFailure('首台设备初始化尚未验收，未发送密码或生成新码。');
    }
    if (_initializationState != 'none') {
      throw const GatewayFailure('已有原初始化意图；请查询或完整重输原新码，不能另建。');
    }
    final cleanName = _environmentName(name);
    _initializationState = 'unknown';
    final code = await (gateway as InitializationGateway).beginInitialization(
      email,
      password,
      cleanName,
    );
    if (epoch != _epoch) return;
    _initializationCode = code;
    _initializationState = 'pending-full-reentry';
  });

  Future<void> completeInitialization(String fullCodeReentry) =>
      _run((epoch) async {
        if (_session.stage != SessionStage.deviceAuthorization ||
            !supports('completeInitialization') ||
            gateway is! InitializationGateway ||
            _initializationState == 'none') {
          throw const GatewayFailure('没有可继续的已验首机初始化意图。');
        }
        final session = await (gateway as InitializationGateway)
            .completeInitialization(fullCodeReentry);
        if (epoch != _epoch) return;
        _initializationCode = null;
        _initializationState = 'complete';
        _applySession(session);
        await _pullRestoredSession(epoch);
      });

  Future<void> queryInitialization() => _run((epoch) async {
    if (!supports('queryInitialization') || gateway is! InitializationGateway) {
      throw const GatewayFailure('原初始化状态查询尚未接通。');
    }
    final state = await (gateway as InitializationGateway)
        .queryInitialization();
    if (epoch != _epoch) return;
    _initializationState = state;
  });

  Future<void> resumeInitialization() => _run((epoch) async {
    if (!serverVerified ||
        !supports('queryInitialization') ||
        gateway is! InitializationGateway) {
      throw const GatewayFailure('原首机初始化查询尚未接通。');
    }
    final state = await (gateway as InitializationGateway)
        .queryInitialization();
    if (epoch != _epoch) return;
    if (!{'pending', 'absent', 'complete'}.contains(state)) {
      throw const GatewayFailure('本机没有可继续的原首机初始化；没有创建新意图。');
    }
    _applySession(const VaultSession(SessionStage.deviceAuthorization));
    _initializationState = state;
    _locations.add(const VaultLocation(VaultPage.initialization));
  });

  Future<void> queryBusinessPending() => _run((epoch) async {
    if (!supports('businessPendingInfo') ||
        gateway is! BusinessPendingGateway) {
      throw const GatewayFailure('原操作查询尚未验收，未生成新 ID。');
    }
    final pending = await (gateway as BusinessPendingGateway)
        .businessPendingInfo();
    if (epoch != _epoch) return;
    _businessPending = List.unmodifiable(pending);
    if (_vaultSuspended &&
        !pending.any((item) => item.canRetry) &&
        supports('restoreSession')) {
      final session = await (gateway as SessionVaultGateway).restoreSession();
      if (epoch != _epoch) return;
      _applySession(session);
      await _pullRestoredSession(epoch);
    }
  });

  Future<void> retryBusinessPending(String id) => _run((epoch) async {
    if (!supports('retryBusinessOperation') ||
        gateway is! BusinessPendingGateway ||
        !_businessPending.any((item) => item.id == id && item.canRetry)) {
      throw const GatewayFailure('仅可续办已核验列表中的原操作 ID。');
    }
    final resolved = await (gateway as BusinessPendingGateway)
        .retryBusinessOperation(id);
    if (epoch != _epoch) return;
    _businessPending = List.unmodifiable([
      for (final item in _businessPending) item.id == id ? resolved : item,
    ]);
    if (!resolved.applied) {
      throw const GatewayFailure(
        '原操作尚未完成验签下发与密封保存；不能报告成功。',
        suspendVault: true,
      );
    }
    if (!supports('restoreSession')) {
      throw const GatewayFailure('原操作已保存，可信视图恢复尚未接通。');
    }
    final session = await (gateway as SessionVaultGateway).restoreSession();
    if (epoch != _epoch) return;
    _applySession(session);
    await _pullRestoredSession(epoch);
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
    _retireSensitiveForm();
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
    if (epoch != _epoch) return;
    if (gateway is ApprovalContinuationGateway) {
      _approvalProgress =
          (gateway as ApprovalContinuationGateway).approvalProgress;
      if (_approvalProgress.state != 'complete') _suspendVault();
    }
  });
  Future<void> queryApproval() => _run((epoch) async {
    if (!supports('queryApproval') || gateway is! ApprovalContinuationGateway) {
      throw const GatewayFailure('原审批状态查询尚未接通。');
    }
    final status = await (gateway as ApprovalContinuationGateway)
        .queryApproval();
    if (epoch != _epoch) return;
    _approvalProgress = status;
    if (status.state == 'none' || status.state == 'complete') {
      final session = await (gateway as SessionVaultGateway).restoreSession();
      if (epoch != _epoch) return;
      _applySession(session);
      await _pullRestoredSession(epoch);
    }
  });
  Future<void> retryApproval() => _run((epoch) async {
    if (!supports('retryApproval') ||
        gateway is! ApprovalContinuationGateway ||
        !_approvalProgress.canRetry ||
        _approvalProgress.pairingId.isEmpty) {
      throw const GatewayFailure('只有原审批ID可以查询并续办，不生成新签名。');
    }
    final status = await (gateway as ApprovalContinuationGateway).retryApproval(
      _approvalProgress.pairingId,
    );
    if (epoch != _epoch) return;
    _approvalProgress = status;
    if (status.state != 'complete') {
      throw const GatewayFailure('管理者审批已提交，对方设备完成仍未确认。', suspendVault: true);
    }
    final session = await (gateway as SessionVaultGateway).restoreSession();
    if (epoch != _epoch) return;
    _applySession(session);
    await _pullRestoredSession(epoch);
  });
  Future<void> cancelApproval() => _run((epoch) async {
    if (!supports('cancelApproval') ||
        gateway is! ApprovalContinuationGateway ||
        !_approvalProgress.canCancel ||
        _approvalProgress.pairingId.isEmpty) {
      throw const GatewayFailure('仅未尝试HTTP的prepared原审批可取消。');
    }
    await (gateway as ApprovalContinuationGateway).cancelApproval(
      _approvalProgress.pairingId,
    );
    if (epoch != _epoch) return;
    _approvalProgress = const DeviceApprovalProgress(state: 'none');
    final session = await (gateway as SessionVaultGateway).restoreSession();
    if (epoch != _epoch) return;
    _applySession(session);
    await _pullRestoredSession(epoch);
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
      if (!_retainedForm &&
          _busy &&
          _activeOperation != null &&
          _foreground &&
          !_privacyLocked &&
          !_vaultSuspended &&
          !_nativeCleanupPending) {
        _retainedForm = true;
        // 本次表单内存寿命上限；不是原生认证期限或认证已验。
        _boundFormRetention(const Duration(seconds: 120));
      }
      _privacyMask = true;
      _notify();
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
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
      _formRetentionTimer?.cancel();
      _formRetentionTimer = null;
      _retainedForm = false;
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
    if (!value) {
      _retireSensitiveForm();
      _clearManagementList();
      if (_managementRunning) _suspendVault();
      if (gateway is DeviceManagementGateway) {
        (gateway as DeviceManagementGateway).retireManagementResults();
      }
      if (_recoveryFlow.active) {
        _recoveryFlow.invalidate();
        _suspendVault();
      }
      // native lifecycle 独立退役 registry；Dart 立即丢弃晚到返回和新码。
    }
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
    _recoveryFlow.dispose();
    _resetLocalSession();
    super.dispose();
  }
}
