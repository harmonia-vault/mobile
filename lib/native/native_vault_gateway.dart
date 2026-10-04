import 'dart:async';
import 'dart:convert';

import '../account_reset/account_reset_gateway.dart';
import '../account_reset/account_reset_host.dart';
import '../account_reset/account_reset_presentation.dart';
import 'native_account_reset_adapter.dart';
import 'native_account_reset_channel.dart';

import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

import '../vault_controller.dart';
import '../management/management_gateway.dart';
import '../pairing/pending_pairing_gateway.dart';
import 'native_pending_pairings_adapter.dart';
import '../management/management_presentation.dart';
import 'native_management_contract.dart';
import '../recovery/recovery_gateway.dart';
import 'native_dag_recovery_adapter.dart';
import 'native_business_adapter.dart';
import 'native_fixture_connection.dart';
import 'native_pin_adapter.dart';
import 'native_ui_contract.dart';
import 'native_workflow_adapter.dart';

/// 可替换的公开意图传输边界；测试夹具不证明真实系统认证。
abstract interface class NativeGatewayPort {
  Future<Map<String, Object?>> capabilities();
  Future<Map<String, Object?>> profile();
  Future<Map<String, Object?>> validateEndpoint(String endpoint);
  Future<Map<String, Object?>> createDevice();
  Future<Map<String, Object?>> execute(
    String endpoint,
    String operation,
    Map<String, String> fields,
  );
  Future<Map<String, Object?>> approve(
    String endpoint,
    int version,
    String pairingId,
    Uint8List shortCode,
    List<NativeApprovalSelection> selections,
  );
}

abstract interface class NativeLocalProtectionPort {
  Future<LocalProtectionStatus> localProtectionInfo(String endpoint);
}

abstract interface class NativeFixtureConnectionPort {
  Future<Map<String, Object?>> fixtureConnectionInfo();
}

class MethodChannelGatewayPort
    implements
        NativeGatewayPort,
        NativeFixtureConnectionPort,
        NativeLocalProtectionPort,
        NativeDAGRecoveryPort,
        NativeDAGProfilePort,
        NativePendingPairingsPort {
  const MethodChannelGatewayPort();
  @override
  Future<Map<String, Object?>> executePendingPairings(
    String endpoint,
    String operation,
  ) => const NativePendingPairingsAdapter().executePendingPairings(
    endpoint,
    operation,
  );
  @override
  Future<Map<String, Object?>> dagWorkflowProfile() =>
      const NativeDAGRecoveryAdapter().dagWorkflowProfile();
  @override
  Future<Map<String, Object?>> executeDAGRecovery(
    String endpoint,
    String operation,
    Map<String, String> fields,
    Uint8List completeCode,
  ) => const NativeDAGRecoveryAdapter().executeDAGRecovery(
    endpoint,
    operation,
    fields,
    completeCode,
  );
  @override
  Future<LocalProtectionStatus> localProtectionInfo(String endpoint) =>
      NativePINAdapter(endpoint).information();
  @override
  Future<Map<String, Object?>> fixtureConnectionInfo() async {
    const channel = MethodChannel('org.harmoniavault/native/v1');
    final value = await channel.invokeMapMethod<String, Object?>(
      'fixtureConnectionInfo',
    );
    if (value == null) throw const GatewayFailure('没有原生测试flavor证明。');
    return Map.unmodifiable(value);
  }

  @override
  Future<Map<String, Object?>> capabilities() =>
      const NativeBusinessAdapter().capabilities();
  @override
  Future<Map<String, Object?>> profile() =>
      const NativeWorkflowAdapter('').profile();
  @override
  Future<Map<String, Object?>> validateEndpoint(String endpoint) =>
      const NativeBusinessAdapter().validateEndpoint(endpoint);
  @override
  Future<Map<String, Object?>> createDevice() =>
      const NativeBusinessAdapter().createProtectedDevice();
  @override
  Future<Map<String, Object?>> execute(
    String endpoint,
    String operation,
    Map<String, String> fields,
  ) {
    final a = NativeWorkflowAdapter(endpoint);
    String f(String key) => fields[key]!;
    return switch (operation) {
      'register' => a.register(f('email'), f('password')),
      'verifyEmail' => a.verifyEmail(
        accountId: f('accountId'),
        accountGeneration: f('accountGeneration'),
        challengeId: f('challengeId'),
        token: f('token'),
      ),
      'loginAccount' => a.loginAccount(f('email'), f('password')),
      'restoreSession' => a.restoreSession(),
      'view' => a.view(),
      'pull' => a.pull(),
      'beginInitialization' => a.beginInitialization(
        email: f('email'),
        password: f('password'),
        name: f('name'),
        id: f('id'),
      ),
      'completeInitialization' => a.completeInitialization(f('recoveryCode')),
      'queryInitialization' => a.queryInitialization(),
      'createEnvironment' => a.createEnvironment(f('name'), f('id')),
      'renameEnvironment' => a.renameEnvironment(
        f('environmentId'),
        f('name'),
        f('id'),
      ),
      'deleteEnvironment' => a.deleteEnvironment(f('environmentId'), f('id')),
      'setVariable' => a.setVariable(
        environmentId: f('environmentId'),
        name: f('name'),
        value: f('value'),
        id: f('id'),
      ),
      'deleteVariable' => a.deleteVariable(
        f('environmentId'),
        f('name'),
        f('id'),
      ),
      'businessPendingInfo' => a.businessPendingInfo(),
      'approvalInfoV3' => a.approvalInfoV3(),
      'retryApprovalV3' => a.retryApprovalV3(f('pairingId')),
      'cancelApprovalV3' => a.cancelApprovalV3(f('pairingId')),
      'approvalInfoV4' => a.approvalInfoV4(),
      'retryApprovalV4' => a.retryApprovalV4(f('pairingId')),
      'cancelApprovalV4' => a.cancelApprovalV4(f('pairingId')),
      'retryBusinessOperation' => a.retryBusinessOperation(f('id')),
      'managementDevices' => a.managementDevices(f('environmentId')),
      'prepareDeviceGrant' => a.prepareDeviceGrant(
        environmentId: f('environmentId'),
        subjectDeviceId: f('subjectDeviceId'),
        role: f('role'),
        expiresAt: f('expiresAt'),
        id: f('id'),
      ),
      'prepareOtherDeviceRevocation' => a.prepareOtherDeviceRevocation(
        environmentId: f('environmentId'),
        subjectDeviceId: f('subjectDeviceId'),
        id: f('id'),
      ),
      'managementInfo' => a.managementInfo(),
      'retryManagement' => a.retryManagement(f('id')),
      'cancelManagement' => a.cancelManagement(f('id')),
      'logout' => a.logout(),
      _ => throw const GatewayFailure('未接通此明确原生业务意图。'),
    };
  }

  @override
  Future<Map<String, Object?>> approve(
    String endpoint,
    int version,
    String pairingId,
    Uint8List shortCode,
    List<NativeApprovalSelection> selections,
  ) {
    final a = NativeWorkflowAdapter(endpoint);
    return switch (version) {
      2 => a.approvePairing(
        pairingId: pairingId,
        shortCode: shortCode,
        selections: selections,
      ),
      3 => a.approvePairingV3(
        pairingId: pairingId,
        shortCode: shortCode,
        selections: selections,
      ),
      4 => a.approvePairingV4(
        pairingId: pairingId,
        shortCode: shortCode,
        selections: selections,
      ),
      _ => throw const GatewayFailure('本次流程没有已核验的明确审批版本。'),
    };
  }
}

/// 单操作同时满足公开profile与独立实测证据；整体ready继续false。
/// 新四意图依据公开core32b02936/mobilec754a59f同源Android3/3验收；
/// Flutter产品点击链另验，运行时profile仍不得单独授予能力。
class NativeVaultGateway
    implements
        SessionVaultGateway,
        InstanceConnectionGateway,
        ServerScopeGateway,
        InitializationGateway,
        EmailProofGateway,
        ApprovalContinuationGateway,
        BusinessPendingGateway,
        LocalProtectionGateway,
        RecoveryGateway,
        DeviceManagementGateway,
        PendingPairingGateway,
        AccountResetGatewayProvider {
  NativeVaultGateway({
    required this.experimentalOptIn,
    this.productFixture = false,
    NativeGatewayPort? port,
    Set<String>? verifiedNativeOperations,
    Set<String>? verifiedPINOperations,
    Set<String> verifiedDAGOperations = const {},
    Set<String> verifiedManagementOperations = const {},
    Set<String> verifiedPendingPairingOperations = const {},
    Set<AccountResetAction> verifiedAccountResetActions = const {},
    DateTime Function()? now,
    Future<InstanceDescriptor> Function(String)? inspector,
  }) : _port = port ?? const MethodChannelGatewayPort(),
       _verifiedOperations = Set.unmodifiable(
         verifiedNativeOperations ?? _nativeEvidence,
       ),
       _verifiedPINOperations = Set.unmodifiable(
         verifiedPINOperations ?? _pinEvidence,
       ),
       _verifiedDAGOperations = Set.unmodifiable(verifiedDAGOperations),
       _verifiedManagementOperations = Set.unmodifiable(
         verifiedManagementOperations,
       ),
       _verifiedPendingPairingOperations = Set.unmodifiable(
         verifiedPendingPairingOperations,
       ),
       _verifiedAccountResetActions = Set.unmodifiable(
         verifiedAccountResetActions,
       ),
       _now = now ?? DateTime.now,
       _inspector = inspector ?? inspectHarmoniaInstance;
  final Set<AccountResetAction> _verifiedAccountResetActions;
  Set<AccountResetAction> _compiledAccountResetActions = const {};
  @override
  AccountResetGateway createAccountResetGateway() {
    final epoch = _scopeEpoch, endpoint = _endpoint;
    final declared =
        experimentalOptIn && !_cleanupPending && _inspected.contains(endpoint)
        ? _compiledAccountResetActions
        : <AccountResetAction>{};
    return ScopedAccountResetGateway(
      NativeAccountResetAdapter(
        port: const MethodChannelAccountResetPort(),
        compiledActions: declared,
        verifiedActions: _verifiedAccountResetActions,
      ),
      endpoint,
      () => epoch == _scopeEpoch && endpoint == _endpoint && !_cleanupPending,
    );
  }

  @override
  void retireAccountResetProjection() {
    // 只撤RAM显示来源；不改scopeEpoch，不给native cleanup回调或物理删除声明。
    retireManagementResults();
    retireRecoveryResults();
    retirePendingPairingResults();
    _trusted = null;
    _checkpoint = 0;
    _approvalVersion = 0;
  }

  final bool experimentalOptIn, productFixture;
  ProductFixtureConnection? _fixtureConnection;
  final NativeGatewayPort _port;
  final Set<String> _verifiedOperations;
  final Set<String> _verifiedPINOperations;
  final Set<String> _verifiedDAGOperations;
  final Set<String> _verifiedManagementOperations;
  int _managementEpoch = 0;
  String? _managementPreparingOperation;
  ManagementOperation _managementOperation = const ManagementOperation(
    phase: ManagementPhase.idle,
  );
  @override
  ManagementOperation get managementOperation => _managementOperation;
  @override
  Set<String> get managementCapabilities => Set.unmodifiable({
    if (!_dagSelected && !_cleanupPending && _endpoint.isNotEmpty)
      for (final op in managementOperations)
        if (_has(op)) op,
  });
  @override
  void retireManagementResults() {
    _managementEpoch++;
    _managementPreparingOperation = null;
  }

  bool _managementCurrent(int epoch, int scope) =>
      epoch == _managementEpoch && scope == _scopeEpoch && !_cleanupPending;
  ManagementOperation _managementUnknown(ManagementOperation p) =>
      ManagementOperation(
        phase: ManagementPhase.unknown,
        id: p.id,
        kind: p.kind,
        environmentId: p.environmentId,
        subjectDeviceId: p.subjectDeviceId,
        attempted: p.attempted,
        sequence: p.sequence,
        acceptanceUnknown: true,
        requestExpiresAt: p.requestExpiresAt,
      );
  void _adoptManagement(ManagementOperation next) {
    final prior = _managementOperation;
    if (prior.unresolved) {
      if (next.phase == ManagementPhase.idle ||
          prior.id != next.id ||
          prior.kind != next.kind ||
          prior.environmentId != next.environmentId ||
          prior.subjectDeviceId != next.subjectDeviceId ||
          prior.sequence > next.sequence ||
          prior.attempted && !next.attempted) {
        throw const GatewayFailure(
          '原管理操作或接受下界改变；保留原ID，不能新建意图。',
          suspendVault: true,
        );
      }
    }
    _managementOperation = next;
  }

  void _managementPermission(String environmentId) {
    if (_trusted == null ||
        _pendingUnknown ||
        _managementOperation.unresolved ||
        !_trusted!.view.environments.any(
          (e) => e.id == environmentId && e.role == AccessRole.admin,
        )) {
      throw const GatewayFailure('须有当前已验Admin环境，且没有其它未决操作。');
    }
  }

  void _invalidateManagementTrust() {
    retireManagementResults();
    _managementOperation = const ManagementOperation(
      phase: ManagementPhase.idle,
    );
    _trusted = null;
  }

  Future<NativeManagementEnvelope> _managementCall(
    String op,
    Map<String, String> fields, {
    String? originalId,
  }) async {
    final epoch = _managementEpoch, scope = _scopeEpoch;
    try {
      final raw = await _execute(op, fields, originalId: originalId);
      if (!_managementCurrent(epoch, scope)) {
        throw const GatewayFailure('原管理范围已退役，丢弃晚到结果。');
      }
      final envelope = decodeManagementEnvelope(
        raw,
        op,
        originalId: originalId,
      );
      if (envelope.failure?.trustInvalidated == true) {
        _invalidateManagementTrust();
      }
      return envelope;
    } on NativeIntentFailure catch (error) {
      if (_managementCurrent(epoch, scope) && error.trustInvalidated) {
        _invalidateManagementTrust();
      }
      rethrow;
    }
  }

  @override
  Future<ManagementOperation> inspectManagement() async {
    final result = await _managementCall('managementInfo', const {});
    if (result.failure != null) throw result.failure!;
    final info = decodeManagementInfo(result.data);
    _adoptManagement(info);
    return info;
  }

  @override
  Future<List<ManagedDeviceAccess>> managementDevices(
    String environmentId,
  ) async {
    _require('managementDevices');
    _managementPermission(environmentId);
    if (!nativeIdentifier(environmentId)) throw const GatewayFailure('环境标识无效。');
    final result = await _managementCall('managementDevices', {
      'environmentId': environmentId,
    });
    if (result.failure != null) throw result.failure!;
    return decodeManagementDevices(result.data, environmentId, _deviceId);
  }

  bool _managementNotDispatched(Object error) =>
      error is NativeIntentFailure &&
      const {
        'AUTH_CANCELLED',
        'AUTH_FAILED',
        'AUTH_UNAVAILABLE',
        'PROTECTED_KEYS_UNAVAILABLE',
        'BUSY',
        'LOCKED',
        'INVALID_COMMAND',
        'PIN_CANCELLED',
        'PIN_AUTH_FAILED',
        'PIN_BLOCKED',
      }.contains(error.code);
  Future<ManagementOperation> _prepareManagement(
    String op,
    Map<String, String> fields,
    String kind,
  ) async {
    _require(op);
    _managementPermission(fields['environmentId']!);
    if (!nativeIdentifier(fields['environmentId']!) ||
        !nativeIdentifier(fields['subjectDeviceId']!)) {
      throw const GatewayFailure('环境或设备标识无效。');
    }
    final id = _newId(), epoch = _managementEpoch, scope = _scopeEpoch;
    final original = ManagementOperation(
      phase: ManagementPhase.unknown,
      id: id,
      kind: kind,
      environmentId: fields['environmentId']!,
      subjectDeviceId: fields['subjectDeviceId']!,
      acceptanceUnknown: true,
    );
    final prior = _managementOperation;
    // 在原生调用前保留原ID，但尚不声称prepared或已尝试提交。
    _managementOperation = original;
    _managementPreparingOperation = op;
    try {
      final result = await _managementCall(op, {
        ...fields,
        'id': id,
      }, originalId: id);
      if (result.failure != null) throw result.failure!;
      final info = decodeManagementInfo(result.data);
      if (info.id != id ||
          info.kind != kind ||
          info.environmentId != original.environmentId ||
          info.subjectDeviceId != original.subjectDeviceId ||
          info.phase != ManagementPhase.prepared) {
        throw const GatewayFailure('原准备结果与明确管理意图不一致。', suspendVault: true);
      }
      _managementOperation = info;
      return info;
    } catch (error) {
      if (_managementCurrent(epoch, scope)) {
        _managementOperation = _managementNotDispatched(error)
            ? prior
            : original;
      }
      rethrow;
    } finally {
      if (_managementCurrent(epoch, scope)) {
        _managementPreparingOperation = null;
      }
    }
  }

  @override
  Future<ManagementOperation> prepareDeviceGrant({
    required String environmentId,
    required String subjectDeviceId,
    required ManagedRole role,
    required ManagementExpiry expiry,
  }) async {
    if (role == ManagedRole.ungranted ||
        role == ManagedRole.none && expiry.at != null ||
        expiry.at != null &&
            expiry.at!.millisecondsSinceEpoch ~/ 1000 <=
                _now().millisecondsSinceEpoch ~/ 1000) {
      throw const GatewayFailure('须明确选择有效角色与未来期限；移除授权使用明确的0期限。');
    }
    return _prepareManagement('prepareDeviceGrant', {
      'environmentId': environmentId,
      'subjectDeviceId': subjectDeviceId,
      'role': role.wireValue,
      'expiresAt': expiry.at == null
          ? '0'
          : (expiry.at!.millisecondsSinceEpoch ~/ 1000).toString(),
    }, 'grant');
  }

  @override
  Future<ManagementOperation> prepareOtherDeviceRevocation({
    required String environmentId,
    required String subjectDeviceId,
  }) async {
    if (subjectDeviceId == _deviceId) {
      throw const GatewayFailure('此入口只能撤销其它设备，不能替代本机退出。');
    }
    return _prepareManagement('prepareOtherDeviceRevocation', {
      'environmentId': environmentId,
      'subjectDeviceId': subjectDeviceId,
    }, 'revoke');
  }

  @override
  Future<ManagementOperation> retryManagement(String originalId) async {
    final original = _managementOperation;
    if (!original.unresolved ||
        originalId != original.id ||
        originalId.isEmpty) {
      throw const GatewayFailure('只能续办已保留的原管理ID。');
    }
    final epoch = _managementEpoch, scope = _scopeEpoch;
    try {
      final result = await _managementCall('retryManagement', {
        'id': originalId,
      }, originalId: originalId);
      if (result.failure?.trustInvalidated == true) throw result.failure!;
      final data = decodeManagementResult(
        result.data,
        originalId,
        allowEmptyFailure: result.failure != null,
      );
      if (data.sequence < original.sequence ||
          result.failure != null && data.applied) {
        throw const GatewayFailure('原管理接受下界或失败结果不一致。', suspendVault: true);
      }
      if (data.accepted && !data.applied) {
        _managementOperation = ManagementOperation(
          phase: ManagementPhase.acceptedNotApplied,
          id: originalId,
          kind: original.kind,
          environmentId: original.environmentId,
          subjectDeviceId: original.subjectDeviceId,
          attempted: true,
          sequence: data.sequence,
          requestExpiresAt: original.requestExpiresAt,
        );
      }
      if (result.failure != null) throw result.failure!;
      if (!data.canceled &&
          (!data.accepted || !data.applied || data.acceptanceUnknown)) {
        throw const GatewayFailure('原管理操作尚未完成，不能更新本机显示。', suspendVault: true);
      }
      _managementOperation = ManagementOperation(
        phase: data.canceled
            ? ManagementPhase.cancelled
            : ManagementPhase.applied,
        id: originalId,
        kind: original.kind,
        environmentId: original.environmentId,
        subjectDeviceId: original.subjectDeviceId,
        attempted: !data.canceled,
        sequence: data.sequence,
      );
      return _managementOperation;
    } catch (error) {
      if (_managementCurrent(epoch, scope) &&
          _managementOperation.phase != ManagementPhase.acceptedNotApplied &&
          !_managementNotDispatched(error)) {
        _managementOperation = _managementUnknown(original);
      }
      rethrow;
    }
  }

  @override
  Future<ManagementOperation> cancelManagement(String originalId) async {
    final original = _managementOperation;
    if (original.phase != ManagementPhase.prepared ||
        original.attempted ||
        original.id != originalId ||
        originalId.isEmpty) {
      throw const GatewayFailure('只有未尝试提交的prepared原操作可取消。');
    }
    final epoch = _managementEpoch, scope = _scopeEpoch;
    try {
      final result = await _managementCall('cancelManagement', {
        'id': originalId,
      }, originalId: originalId);
      if (result.failure != null) throw result.failure!;
      _managementOperation = ManagementOperation(
        phase: ManagementPhase.cancelled,
        id: originalId,
        kind: original.kind,
        environmentId: original.environmentId,
        subjectDeviceId: original.subjectDeviceId,
      );
      return _managementOperation;
    } catch (error) {
      if (_managementCurrent(epoch, scope) &&
          !_managementNotDispatched(error)) {
        _managementOperation = _managementUnknown(original);
      }
      rethrow;
    }
  }

  final Set<String> _verifiedPendingPairingOperations;
  Set<String> _compiledPendingPairingOperations = const {};
  int _pendingPairingEpoch = 0;
  bool _pendingPairingReading = false;
  String get _pendingPairingOperation => switch (_approvalVersion) {
    3 => 'pendingPairingRequestsV3',
    4 => 'pendingPairingRequestsV4',
    _ => '',
  };
  @override
  bool get pendingPairingsAvailable =>
      experimentalOptIn &&
      !_dagSelected &&
      _systemStrong &&
      _port is NativePendingPairingsPort &&
      _trusted != null &&
      _trusted!.view.environments.any((e) => e.role == AccessRole.admin) &&
      !_pendingUnknown &&
      !_managementOperation.unresolved &&
      _approvalPendingId == null &&
      _localProtection?.mode != LocalProtectionMode.pin &&
      _localProtection?.mode != LocalProtectionMode.blocked &&
      _localProtection?.upgradeRequired != true &&
      !_cleanupPending &&
      _endpoint.isNotEmpty &&
      _compiledPendingPairingOperations.contains(_pendingPairingOperation) &&
      _verifiedPendingPairingOperations.contains(_pendingPairingOperation);
  @override
  void retirePendingPairingResults() {
    _pendingPairingEpoch++;
  }

  @override
  Future<PendingPairingSnapshot> pendingPairingRequests() async {
    if (!pendingPairingsAvailable || _pendingPairingReading) {
      throw const GatewayFailure('当前设备没有已验证的前台请求读取能力。');
    }
    final epoch = _pendingPairingEpoch, scope = _scopeEpoch;
    final operation = _pendingPairingOperation, before = _trusted!;
    bool current() =>
        epoch == _pendingPairingEpoch &&
        scope == _scopeEpoch &&
        !_cleanupPending &&
        _pendingPairingOperation == operation &&
        !_dagSelected;
    _pendingPairingReading = true;
    try {
      await refreshLocalProtection();
      if (!current() || !pendingPairingsAvailable) {
        throw const GatewayFailure('原请求读取范围已关闭。');
      }
      // Go 此入口每次先新Boot、完整Pull和当前Admin检查；列表不是审批依据。
      final raw = await _platform(
        () => (_port as NativePendingPairingsPort).executePendingPairings(
          _endpoint,
          operation,
        ),
      );
      if (!current() || !pendingPairingsAvailable) {
        throw const GatewayFailure('已丢弃原请求范围的晚到结果。');
      }
      final snapshot = decodePendingPairings(operation, raw);
      final after = _trusted;
      if (after == null ||
          snapshot.accountId != before.session.accountId ||
          snapshot.accountGeneration != before.session.accountGeneration ||
          snapshot.approverDeviceId != before.deviceId ||
          after.session.accountId != before.session.accountId ||
          after.session.accountGeneration != before.session.accountGeneration ||
          after.deviceId != before.deviceId) {
        _trusted = null;
        _approvalVersion = 0;
        retirePendingPairingResults();
        throw const GatewayFailure(
          '请求提示的账号或设备范围改变，已关闭读取。',
          suspendVault: true,
          invalidateSession: true,
        );
      }
      // 明确不从snapshot证书或capabilities设置_approvalVersion/审批权限。
      return snapshot;
    } on NativeIntentFailure catch (failure) {
      if (current() &&
          (failure.trustInvalidated ||
              failure.code == 'LOCAL_PROTECTION_PERSISTENCE')) {
        _trusted = null;
        _approvalVersion = 0;
        retirePendingPairingResults();
        if (failure.code == 'LOCAL_PROTECTION_PERSISTENCE') {
          // 原生槽删除/排空未确认，只有已确认的logout清理才能解除本机闭锁。
          _cleanupPending = true;
          throw GatewayFailure(
            failure.message,
            suspendVault: true,
            invalidateSession: true,
          );
        }
      }
      rethrow;
    } finally {
      _pendingPairingReading = false;
    }
  }

  int _recoveryEpoch = 0;
  bool _dagSelected = false;
  Set<String> _dagRuntimeOperations = const {};
  bool _nativeDAGOwnerCancellation = false;
  RecoveryTrusted? _dagTrusted;

  @override
  bool get recoveryStateMayExist => _protectedDeviceExists;

  @override
  Set<String> get recoveryCapabilities => Set.unmodifiable({
    if (experimentalOptIn &&
        _systemStrong &&
        _port is NativeDAGRecoveryPort &&
        _localProtection?.mode != LocalProtectionMode.pin &&
        _localProtection?.mode != LocalProtectionMode.blocked &&
        _localProtection?.upgradeRequired != true &&
        !_cleanupPending &&
        _endpoint.isNotEmpty)
      for (final op in dagRecoveryFields.keys)
        if ((op == 'cancelDAGRecoveryOwner'
                ? _nativeDAGOwnerCancellation
                : _dagRuntimeOperations.contains(op)) &&
            _verifiedDAGOperations.contains(op))
          op,
  });
  void _requireDAG(String operation) {
    if (!recoveryCapabilities.contains(operation)) {
      throw const GatewayFailure('此 DAG 恢复操作没有逐项原生验收证据或当前能力。');
    }
  }

  @override
  void retireRecoveryResults() {
    _recoveryEpoch++;
    _dagTrusted = null;
  }

  @override
  Future<RecoveryReply> executeRecovery(
    String operation,
    Map<String, String> fields,
    Uint8List completeCode,
  ) async {
    final epoch = _recoveryEpoch, scope = _scopeEpoch;
    final previous = _dagTrusted;
    try {
      _requireDAG(operation);
      await refreshLocalProtection();
      _requireDAG(operation);
      if (operation == 'openDAGRecoveryOwner') await _ensureDevice();
      _requireDAG(operation);
      if (epoch != _recoveryEpoch || scope != _scopeEpoch) {
        throw const GatewayFailure('恢复本机范围已关闭。');
      }
      _dagSelected = true;
      _trusted = null;
      final raw = await _platform(
        () => (_port as NativeDAGRecoveryPort).executeDAGRecovery(
          _endpoint,
          operation,
          fields,
          completeCode,
        ),
      );
      if (epoch != _recoveryEpoch || scope != _scopeEpoch || _cleanupPending) {
        throw const GatewayFailure('已丢弃原恢复范围的晚到结果。');
      }
      final reply = decodeDAGRecovery(operation, raw);
      final result = reply.payload;
      if (result is RecoveryResolution &&
          (operation == 'queryDAGRecoveryResolution' ||
              operation == 'closeDAGRecoveryOriginal') &&
          (result.operationId != fields['operationId'] ||
              result.targetHash != fields['targetHash'])) {
        throw const GatewayFailure('服务器恢复结果不属于当前原操作，已拒绝。');
      }
      if (result is RecoveryTrusted) {
        if (operation == 'applyDAGRecoveredDevice' &&
                (result.operationId != fields['operationId'] ||
                    result.contentHash != fields['contentHash']) ||
            previous != null &&
                (result.accountId != previous.accountId ||
                    result.accountGeneration != previous.accountGeneration ||
                    result.deviceId != previous.deviceId ||
                    result.operationId != previous.operationId ||
                    result.contentHash != previous.contentHash ||
                    result.acceptedSequence != previous.acceptedSequence ||
                    result.snapshot.checkpoint <
                        previous.snapshot.checkpoint)) {
          throw const GatewayFailure(
            '已恢复来源的绑定、原包或检查点改变，已关闭读取。',
            suspendVault: true,
          );
        }
        _dagTrusted = result;
        _deviceId = result.deviceId;
        _checkpoint = result.snapshot.checkpoint;
      }
      return reply;
    } catch (_) {
      if (epoch == _recoveryEpoch && scope == _scopeEpoch) _dagTrusted = null;
      rethrow;
    } finally {
      completeCode.fillRange(0, completeCode.length, 0);
    }
  }

  @override
  Future<void> cancelRecoveryOwner() async {
    retireRecoveryResults();
    _requireDAG('cancelDAGRecoveryOwner');
    final raw = await _platform(
      () => (_port as NativeDAGRecoveryPort).executeDAGRecovery(
        _endpoint,
        'cancelDAGRecoveryOwner',
        const {},
        Uint8List(0),
      ),
    );
    nativeFields(raw, {
      'version',
      'operation',
      'localOwnerClosed',
      'journalPreserved',
      'trustedDevice',
    });
    if (raw['version'] != 1 ||
        raw['operation'] != 'cancelDAGRecoveryOwner' ||
        raw['localOwnerClosed'] != true ||
        raw['journalPreserved'] != true ||
        raw['trustedDevice'] != false) {
      throw const GatewayFailure('本机原生取消结果无效；未确认服务器关闭或原包清除。');
    }
  }

  VaultSnapshot _dagSnapshot(RecoveryTrusted source) => VaultSnapshot(
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

  LocalProtectionStatus? _localProtection;
  bool _pinPreviouslyObserved = false;
  LocalPINPrompt? _pinPrompt;
  LocalPINForgetPrompt? _pinForgetPrompt;
  @override
  LocalProtectionStatus? get localProtectionStatus => _localProtection;
  final DateTime Function() _now;
  final Future<InstanceDescriptor> Function(String) _inspector;
  static const _nativeEvidence = {
    'loginAccount',
    'restoreSession',
    'businessPendingInfo',
    'retryBusinessOperation',
    'register',
    'verifyEmail',
    'beginInitialization',
    'completeInitialization',
    'queryInitialization',
    'view',
    'pull',
    'createEnvironment',
    'renameEnvironment',
    'deleteEnvironment',
    'setVariable',
    'deleteVariable',
    'approvePairing',
    'retryApproval',
    'approvalInfo',
    'cancelApproval',
    'approvePairingV3',
    'retryApprovalV3',
    'approvalInfoV3',
    'cancelApprovalV3',
    'approvePairingV4',
    'retryApprovalV4',
    'approvalInfoV4',
    'cancelApprovalV4',
    'logout',
  };
  // 逐项来自实际 MainActivity PIN/JNI/HTTPS/CLI3 纵链；不是设备可信声明。
  // V4、恢复、迁移、轮换、管理及未实测查询/取消保持关闭。
  static const _pinEvidence = {
    'register',
    'verifyEmail',
    'loginAccount',
    'beginInitialization',
    'completeInitialization',
    'restoreSession',
    'businessPendingInfo',
    'retryBusinessOperation',
    'createEnvironment',
    'renameEnvironment',
    'deleteEnvironment',
    'setVariable',
    'deleteVariable',
    'approvePairingV3',
    'retryApprovalV3',
    'pull',
  };
  Set<String> _runtimeOperations = const {};
  final Set<String> _inspected = {};
  bool _systemStrong = false, _protectedDeviceExists = false;
  bool _pendingUnknown = false, _cleanupPending = false;
  int _scopeEpoch = 0;
  String _endpoint = '', _deviceId = '';
  String? _initializationId;
  int _approvalVersion = 0;
  int _checkpoint = 0;
  String? _approvalPendingId;
  DeviceApprovalProgress _approvalProgress = const DeviceApprovalProgress(
    state: 'none',
  );
  @override
  DeviceApprovalProgress get approvalProgress => _approvalProgress;
  NativeTrustedProjection? _trusted;
  @override
  bool get synthetic => false;
  Set<String> get runtimeOperations => _runtimeOperations;
  bool get protectedDeviceExists => _protectedDeviceExists;
  bool get realVaultReady => false;
  bool _has(String operation) =>
      experimentalOptIn &&
      (!_managementOperation.unresolved ||
          operation == _managementPreparingOperation ||
          const {
            'managementInfo',
            'retryManagement',
            'cancelManagement',
            'logout',
          }.contains(operation)) &&
      _runtimeOperations.contains(operation) &&
      (_localProtection?.mode == LocalProtectionMode.pin
          ? _localProtection!.pinWorkflowReady &&
                !_localProtection!.upgradeRequired &&
                _localProtection!.systemCapability == 'NO_SYSTEM_AUTH' &&
                !managementOperations.contains(operation) &&
                _verifiedPINOperations.contains(operation)
          : _systemStrong &&
                (managementOperations.contains(operation)
                    ? _verifiedManagementOperations.contains(operation)
                    : _verifiedOperations.contains(operation)));

  @override
  void bindLocalPINCallbacks({
    required LocalPINPrompt prompt,
    required LocalPINForgetPrompt confirmForget,
  }) {
    _pinPrompt = prompt;
    _pinForgetPrompt = confirmForget;
  }

  @override
  Future<void> refreshLocalProtection() async {
    if (!experimentalOptIn ||
        _endpoint.isEmpty ||
        _port is! NativeLocalProtectionPort) {
      return;
    }
    final epoch = _scopeEpoch;
    try {
      final status = await (_port as NativeLocalProtectionPort)
          .localProtectionInfo(_endpoint);
      if (epoch != _scopeEpoch) throw const GatewayFailure('原本机保护范围已关闭。');
      _localProtection = status;
      if (status.mode == LocalProtectionMode.pin || status.upgradeRequired) {
        _pinPreviouslyObserved = true;
      }
      if (status.mode != LocalProtectionMode.system ||
          status.systemCapability != 'SYSTEM_READY') {
        _systemStrong = false;
      }
      if (status.mode == LocalProtectionMode.pin ||
          status.mode == LocalProtectionMode.blocked) {
        _protectedDeviceExists = status.deviceExists;
      }
    } on MissingPluginException {
      if (_pinPreviouslyObserved) {
        _blockLocalProtection();
        throw const GatewayFailure(
          '原PIN状态不可验证，不能切换系统provider。',
          suspendVault: true,
        );
      }
      // 仅从未有PIN的未实现平台沿其既有系统provider，不授PIN能力。
      _localProtection = null;
    } on PlatformException catch (error) {
      if (error.code == 'UNSUPPORTED' && !_pinPreviouslyObserved) {
        _localProtection = null;
        return;
      }
      _blockLocalProtection();
      throw GatewayFailure(
        NativeIntentFailure(_fixedCode(error.code)).message,
        suspendVault: true,
      );
    } catch (_) {
      _blockLocalProtection();
      throw const GatewayFailure('本机保护状态不可验证，已关闭明文与业务能力。', suspendVault: true);
    }
  }

  void _blockLocalProtection() {
    _systemStrong = false;
    _trusted = null;
    _localProtection = LocalProtectionStatus(
      mode: LocalProtectionMode.blocked,
      systemCapability: 'BLOCKED',
      deviceExists:
          _protectedDeviceExists || (_localProtection?.deviceExists ?? false),
      pinSetupAvailable: false,
      upgradeRequired: _localProtection?.upgradeRequired ?? false,
      pinWorkflowReady: false,
      pinForgetAvailable: _localProtection?.pinForgetAvailable ?? false,
      delaySeconds: _localProtection?.delaySeconds ?? 0,
    );
  }

  static String _fixedCode(String code) =>
      RegExp(r'^[A-Z_]{1,64}$').hasMatch(code) ? code : 'REJECTED';

  Future<LocalPINInput> _requestPIN(
    String operation, {
    bool setup = false,
  }) async {
    final callback = _pinPrompt;
    if (callback == null) throw const GatewayFailure('本机PIN输入界面尚未绑定。');
    final epoch = _scopeEpoch;
    final input = await callback(
      LocalPINPromptRequest(
        setup: setup,
        operation: operation,
        delaySeconds: _localProtection?.delaySeconds ?? 0,
      ),
    );
    if (input == null) throw NativeIntentFailure('PIN_CANCELLED');
    if (epoch != _scopeEpoch || _cleanupPending) {
      input.clear();
      throw const GatewayFailure('原设备范围已关闭，未使用本次PIN。');
    }
    return input;
  }

  @override
  Future<void> setupLocalPIN() async {
    await refreshLocalProtection();
    if (_localProtection?.pinSetupAvailable != true ||
        _cleanupPending ||
        _endpoint.isEmpty) {
      throw const GatewayFailure('只有真正没有系统认证能力且无旧设备时才能设置PIN。');
    }
    final epoch = _scopeEpoch;
    final input = await _requestPIN('setupLocalPIN', setup: true);
    try {
      final created = await _platform(
        () => NativePINAdapter(_endpoint).setup(input),
      );
      if (epoch != _scopeEpoch) throw const GatewayFailure('原设备范围已关闭。');
      if (created['version'] != 1 ||
          created['trusted'] != false ||
          created['deviceId'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(created['deviceId'] as String)) {
        throw const GatewayFailure('PIN设置结果不能证明设备可信。');
      }
      _protectedDeviceExists = true;
      await refreshLocalProtection();
    } finally {
      input.clear();
    }
  }

  @override
  Future<void> forgetLocalPIN() async {
    if (_endpoint.isEmpty || _localProtection?.pinForgetAvailable != true) {
      throw const GatewayFailure('没有原生确认的PIN所属清理资格；不能清理系统保护数据。');
    }
    final epoch = _scopeEpoch;
    final confirm = _pinForgetPrompt;
    if (confirm == null || !await confirm()) return;
    if (epoch != _scopeEpoch) throw const GatewayFailure('原设备范围已关闭，未清理不同范围。');
    _scopeEpoch++;
    _cleanupPending = true;
    _trusted = null;
    _pendingUnknown = false;
    _checkpoint = 0;
    _deviceId = '';
    _approvalPendingId = null;
    _approvalVersion = 0;
    _approvalProgress = const DeviceApprovalProgress(state: 'none');
    try {
      await NativePINAdapter(_endpoint).forget();
      _protectedDeviceExists = false;
      _initializationId = null;
      _cleanupPending = false;
      await refreshLocalProtection();
    } on PlatformException catch (error) {
      throw NativeIntentFailure(_fixedCode(error.code));
    }
  }

  Future<Map<String, Object?>> _executeUsingProvider(
    String endpoint,
    String op,
    Map<String, String> fields,
  ) async {
    await refreshLocalProtection();
    _require(op);
    if (_localProtection?.mode != LocalProtectionMode.pin) {
      return _port.execute(endpoint, op, fields);
    }
    final input = await _requestPIN(op);
    try {
      return await NativePINAdapter(endpoint).execute(op, fields, input);
    } finally {
      input.clear();
    }
  }

  Future<Map<String, Object?>> _approveUsingProvider(
    String endpoint,
    int version,
    String pairingId,
    Uint8List code,
    List<NativeApprovalSelection> selections,
  ) async {
    await refreshLocalProtection();
    _require(_approvalOperation);
    if (_localProtection?.mode != LocalProtectionMode.pin) {
      return _port.approve(endpoint, version, pairingId, code, selections);
    }
    final input = await _requestPIN(_approvalOperation);
    try {
      return await NativePINAdapter(endpoint).approve(
        _approvalOperation,
        {
          'pairingId': pairingId,
          'selections': jsonEncode(selections.map((s) => s.toJson()).toList()),
        },
        input,
        code,
      );
    } finally {
      input.clear();
    }
  }

  @override
  Set<String> get capabilities => _dagSelected
      ? const {}
      : Set.unmodifiable({
          for (final op in managementOperations)
            if (_has(op)) op,
          if (_has('register')) 'registerAccount',
          if (_has('verifyEmail')) 'verifyEmail',
          if (_has('loginAccount')) 'loginAccount',
          if (_has('restoreSession') && _has('businessPendingInfo'))
            'restoreSession',
          if (_has('beginInitialization') &&
              _has('completeInitialization') &&
              _has('restoreSession') &&
              _has('businessPendingInfo'))
            'beginInitialization',
          if (_has('completeInitialization') &&
              _has('restoreSession') &&
              _has('businessPendingInfo'))
            'completeInitialization',
          if (_has('queryInitialization')) 'queryInitialization',
          for (final op in const [
            'createEnvironment',
            'renameEnvironment',
            'deleteEnvironment',
            'setVariable',
            'deleteVariable',
            'businessPendingInfo',
            'retryBusinessOperation',
          ])
            if (_has(op)) op,
          if (_approvalVersion != 0 && _has(_approvalOperation))
            'approveDevice',
          if (_has(_approvalInfoOperation)) 'queryApproval',
          if (_has(_approvalRetryOperation)) 'retryApproval',
          if (_has(_approvalCancelOperation)) 'cancelApproval',
        });
  String get _approvalOperation => switch (_approvalVersion) {
    2 => 'approvePairing',
    3 => 'approvePairingV3',
    4 => 'approvePairingV4',
    _ => '',
  };
  String get _approvalInfoOperation => switch (_approvalVersion) {
    3 => 'approvalInfoV3',
    4 => 'approvalInfoV4',
    _ => '',
  };
  String get _approvalRetryOperation => switch (_approvalVersion) {
    3 => 'retryApprovalV3',
    4 => 'retryApprovalV4',
    _ => '',
  };
  String get _approvalCancelOperation => switch (_approvalVersion) {
    3 => 'cancelApprovalV3',
    4 => 'cancelApprovalV4',
    _ => '',
  };

  void _require(String operation) {
    if (_dagSelected && operation != 'logout' ||
        !_has(operation) ||
        _endpoint.isEmpty ||
        _cleanupPending && operation != 'logout') {
      throw const GatewayFailure('此原生操作或服务范围尚未验收，当前不可用。');
    }
  }

  Future<Map<String, Object?>> _platform(
    Future<Map<String, Object?>> Function() action, {
    String? id,
  }) async {
    try {
      return await action();
    } on PlatformException catch (e) {
      final code = RegExp(r'^[A-Z_]{1,64}$').hasMatch(e.code)
          ? e.code
          : 'REJECTED';
      throw NativeIntentFailure(
        code,
        retrySameId:
            id != null &&
            !const {
              'PIN_CANCELLED',
              'PIN_AUTH_FAILED',
              'PIN_UPGRADE_REQUIRED',
            }.contains(code),
        id: id,
      );
    }
  }

  Future<Map<String, Object?>> _execute(
    String op,
    Map<String, String> fields, {
    String? originalId,
  }) async {
    _require(op);
    if (utf8
            .encode(
              jsonEncode({
                'version': 1,
                'operation': op,
                'endpoint': _endpoint,
                ...fields,
              }),
            )
            .length >
        32768) {
      throw const GatewayFailure('完整原生请求超过32768个UTF-8字节，未发送。');
    }
    final epoch = _scopeEpoch, endpoint = _endpoint;
    final result = await _platform(
      () => _executeUsingProvider(endpoint, op, fields),
      id: originalId,
    );
    if (epoch != _scopeEpoch) {
      throw const GatewayFailure('原设备范围已关闭，丢弃晚到的原生结果。');
    }
    return result;
  }

  String _newId() =>
      'mobile-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  @override
  Future<void> initialize(String endpoint) async {
    if (!experimentalOptIn) throw const GatewayFailure('未启用实验原生入口。');
    final epoch = _scopeEpoch;
    _dagRuntimeOperations = const {};
    _nativeDAGOwnerCancellation = false;
    _compiledPendingPairingOperations = const {};
    _compiledAccountResetActions = const {};
    final caps = await _port.capabilities();
    final profile = await _port.profile();
    if (epoch != _scopeEpoch) return;
    final operations = profile['operations'];
    if (caps['version'] != 1 ||
        caps['goCore'] != true ||
        caps['realVaultReady'] != false ||
        caps['protectedDeviceExists'] is! bool ||
        profile['version'] != 1 ||
        profile['experimental'] != true ||
        profile['realVaultReady'] != false ||
        profile['systemAuthenticationPerOperation'] != true ||
        operations is! List ||
        operations.any((v) => v is! String)) {
      throw const GatewayFailure('原生能力配置不符合当前协议，已拒绝。');
    }
    for (final key in [
      'nativeAccountReset',
      'nativeAccountResetEmailRequest',
    ]) {
      if (caps.containsKey(key) && caps[key] is! bool) {
        throw const GatewayFailure('账号重置编译能力配置无效，当前不可用。');
      }
    }
    _compiledAccountResetActions = compiledAccountResetActions(caps);
    _systemStrong = caps['systemStrongAuthentication'] == true;
    if (caps['appPINDeviceExists'] == true) _pinPreviouslyObserved = true;
    _protectedDeviceExists = caps['protectedDeviceExists'] == true;
    _runtimeOperations = Set.unmodifiable(operations.cast<String>());
    final compiledPending = <String>{};
    for (final version in ['3', '4']) {
      final key = 'nativePendingPairingRequestsV$version';
      if (caps.containsKey(key) && caps[key] is! bool) {
        throw const GatewayFailure('前台请求编译能力配置无效。');
      }
      if (caps[key] == true) {
        compiledPending.add('pendingPairingRequestsV$version');
      }
    }
    _compiledPendingPairingOperations = Set.unmodifiable(compiledPending);

    if (_verifiedDAGOperations.isNotEmpty && _port is NativeDAGProfilePort) {
      final dag = await _platform(
        () => (_port as NativeDAGProfilePort).dagWorkflowProfile(),
      );
      if (epoch != _scopeEpoch) return;
      _dagRuntimeOperations = decodeDAGWorkflowProfile(dag);
      if (caps.containsKey('nativeDAGOwnerCancellation') &&
          caps['nativeDAGOwnerCancellation'] is! bool) {
        _dagRuntimeOperations = const {};
        throw const GatewayFailure('本机恢复取消能力配置无效，当前不可用。');
      }
      _nativeDAGOwnerCancellation = caps['nativeDAGOwnerCancellation'] == true;
    }

    if (productFixture) {
      if (!kDebugMode || _port is! NativeFixtureConnectionPort) {
        throw const GatewayFailure('测试CA入口只在独立debug flavor可用。');
      }
      final attestation = await (_port as NativeFixtureConnectionPort)
          .fixtureConnectionInfo();
      if (epoch != _scopeEpoch) return;
      _fixtureConnection = ProductFixtureConnection.fromNative(
        attestation,
        debugBuild: kDebugMode,
      );
      final canonical = await _port.validateEndpoint(
        _fixtureConnection!.endpoint,
      );
      if (canonical['version'] != 1 ||
          canonical['endpoint'] != _fixtureConnection!.endpoint) {
        _fixtureConnection = null;
        throw const GatewayFailure('测试flavor固定地址不是原生规范HTTPS地址。');
      }
    }
  }

  @override
  Future<InstanceDescriptor> inspectInstance(String endpoint) async {
    final canonical = await _port.validateEndpoint(endpoint);
    if (canonical['version'] != 1 || canonical['endpoint'] != endpoint) {
      throw const GatewayFailure('服务地址不是原生认可的规范HTTPS地址。');
    }
    final fixture = _fixtureConnection;
    if (productFixture && fixture == null) {
      throw const GatewayFailure('测试flavor未完成局部CA验证，未发送连接请求。');
    }
    final instance = fixture == null
        ? await _inspector(endpoint)
        : await inspectHarmoniaInstance(
            endpoint,
            clientFactory: () => fixture.clientFor(endpoint),
          );
    _inspected.add(endpoint);
    return instance;
  }

  @override
  void bindVerifiedServer(String endpoint) {
    if (_cleanupPending ||
        !_inspected.contains(endpoint) ||
        _endpoint.isNotEmpty &&
            _endpoint != endpoint &&
            _protectedDeviceExists) {
      throw const GatewayFailure('须先真实验证服务并完成旧设备原生清理，不能替换范围。');
    }
    if (_endpoint != endpoint) _scopeEpoch++;
    _endpoint = endpoint;
  }

  Future<void> _ensureDevice() async {
    final epoch = _scopeEpoch;
    await refreshLocalProtection();
    if (_localProtection?.mode == LocalProtectionMode.pin) {
      if (!_localProtection!.deviceExists ||
          _localProtection!.upgradeRequired) {
        throw const GatewayFailure('本机PIN状态不能创建或解锁设备。');
      }
      _protectedDeviceExists = true;
      return;
    }
    final caps = await _port.capabilities();
    if (epoch != _scopeEpoch || _cleanupPending) {
      throw const GatewayFailure('原设备范围已关闭，未生成新钥匙。');
    }
    if (caps['version'] != 1 || caps['protectedDeviceExists'] is! bool) {
      throw const GatewayFailure('无法确认本机钥匙状态，拒绝覆盖。');
    }
    _protectedDeviceExists = caps['protectedDeviceExists'] == true;
    if (_protectedDeviceExists) return;
    final created = await _platform(_port.createDevice);
    if (epoch != _scopeEpoch || _cleanupPending) {
      throw const GatewayFailure('已关闭原设备范围，不能继续传递账号凭据。');
    }
    if (created['version'] != 1 ||
        created['trusted'] != false ||
        created['deviceId'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(created['deviceId'] as String)) {
      throw const GatewayFailure('新设备公钥结果无效；它不能证明设备可信。');
    }
    _protectedDeviceExists = true;
  }

  @override
  Future<AccountAuthentication> loginAccount(
    String email,
    String password,
  ) async {
    _require('loginAccount');
    await _ensureDevice();
    return decodeAccountAuthentication(
      nativeData(
        await _execute('loginAccount', {'email': email, 'password': password}),
      ),
    );
  }

  @override
  Future<AccountRegistration> registerAccount(
    String email,
    String password,
  ) async {
    _require('register');
    await _ensureDevice();
    final data = NativeRegistration.parse(
      nativeData(
        await _execute('register', {'email': email, 'password': password}),
      ),
    );
    return AccountRegistration(
      accountId: data.accountId,
      accountGeneration: data.accountGeneration,
      verificationRequired: data.verificationRequired,
    );
  }

  @override
  Future<void> verifyEmail(
    AccountRegistration registration,
    String challengeId,
    String token,
  ) async {
    nativeData(
      await _execute('verifyEmail', {
        'accountId': registration.accountId,
        'accountGeneration': registration.accountGeneration,
        'challengeId': challengeId,
        'token': token,
      }),
    );
  }

  @override
  Future<VaultSession> restoreSession() async {
    if (_dagSelected) {
      final reply = await executeRecovery(
        'restoreDAGRecoveredDevice',
        const {},
        Uint8List(0),
      );
      return (reply.payload as RecoveryTrusted).session;
    }
    _require('restoreSession');
    final projection = NativeTrustedProjection.parse(
      nativeData(await _execute('restoreSession', {})),
    );
    final pending = NativePendingOperation.parseList(
      nativeData(await _execute('businessPendingInfo', {})),
    );
    _pendingUnknown = pending.any((item) => item.canRetry);
    final previous = _trusted;
    final sameExplicitScope =
        previous != null &&
        previous.session.accountId == projection.session.accountId &&
        previous.session.accountGeneration ==
            projection.session.accountGeneration &&
        previous.deviceId == projection.deviceId;
    _trusted = projection;
    _deviceId = projection.deviceId;
    _checkpoint = projection.view.checkpoint;
    // 恢复投影没有来源证书版本，绝不据公钥/root猜测或自动fallback。
    if (!sameExplicitScope) _approvalVersion = 0;
    return VaultSession.withBusinessPending(projection.session, pending);
  }

  @override
  Future<VaultSnapshot> pull() async {
    if (_dagSelected) {
      if (_dagTrusted == null) {
        throw const GatewayFailure('已恢复设备需重新进行正式本机验证。', suspendVault: true);
      }
      try {
        final reply = await executeRecovery(
          'pullDAGRecoveredDevice',
          const {},
          Uint8List(0),
        );
        return _dagSnapshot(reply.payload as RecoveryTrusted);
      } catch (_) {
        throw const GatewayFailure(
          '已恢复设备的正式拉取未完成，明文视图已关闭；请重新验证原来源。',
          suspendVault: true,
        );
      }
    }
    if (_trusted == null) {
      throw const GatewayFailure('须先通过原生可信视图恢复，不能靠登录读取。');
    }
    final raw = nativeObject(nativeData(await _execute('pull', {})), '拉取');
    final view = decodeNativeView(raw);
    if (raw['deviceId'] != _deviceId || view.checkpoint < _checkpoint) {
      throw const GatewayFailure('原生视图绑定或检查点改变，已关闭显示。', suspendVault: true);
    }
    _checkpoint = view.checkpoint;
    _trusted = NativeTrustedProjection(_trusted!.session, _deviceId, view);
    return VaultSnapshot(
      checkpoint: view.checkpoint,
      environments: view.environments,
      devices: [
        VaultDevice(
          id: _deviceId,
          name: '本机',
          platform: 'Android',
          current: true,
          accessSummary: view.environments
              .map((e) => '${e.name}：${e.role.label}')
              .join('；'),
          expiresLabel: '按原生已验授权生效',
        ),
      ],
    );
  }

  @override
  Future<void> submit(PreviewMutation mutation) async {
    if (_trusted == null || _pendingUnknown) {
      throw const GatewayFailure(
        '没有已验可信视图或原事务尚未确认；先查询原操作。',
        suspendVault: true,
      );
    }
    final op = mutation.operation.name;
    _require(op);
    final fields = <String, String>{
      if (mutation.environmentId != null)
        'environmentId': mutation.environmentId!,
      if (mutation.name != null) 'name': mutation.name!,
      if (mutation.value != null) 'value': mutation.value!,
    };
    // 先校验大小，不能把尚未发送的过大请求标成已提交。
    if (utf8
            .encode(
              jsonEncode({
                'version': 1,
                'operation': op,
                'endpoint': _endpoint,
                ...fields,
                'id': 'mobile-${'0' * 32}',
              }),
            )
            .length >
        32768) {
      throw const GatewayFailure('完整请求过大，未生成或提交新事务。');
    }
    final epoch = _scopeEpoch, endpoint = _endpoint;
    final id = _newId();
    fields['id'] = id;
    _pendingUnknown = true;
    try {
      final result = await _execute(op, fields, originalId: id);
      final raw = nativeObject(nativeData(result, originalId: id), '写入视图');
      final view = decodeNativeView(raw);
      if (raw['deviceId'] != _deviceId || view.checkpoint < _checkpoint) {
        throw const GatewayFailure('写入返回的设备绑定或检查点无效。', suspendVault: true);
      }
      _pendingUnknown = false;
    } on NativeIntentFailure catch (failure) {
      if (epoch != _scopeEpoch || endpoint != _endpoint || _cleanupPending) {
        throw const GatewayFailure('原写入所属的会话已结束，已丢弃晚到错误。');
      }
      // 平台在Go前确定拒绝，没有POST/签包；可解除本次本地等待。
      // Go/密封异常和HTTP结果不明仍必须原ID查询，不能推测未发送。
      if (const {
        'PIN_CANCELLED',
        'PIN_AUTH_FAILED',
        'PIN_UPGRADE_REQUIRED',
        'AUTH_CANCELLED',
        'AUTH_FAILED',
        'AUTH_UNAVAILABLE',
        'PROTECTED_KEYS_UNAVAILABLE',
        'BUSY',
        'LOCKED',
        'INVALID_COMMAND',
      }.contains(failure.code)) {
        _pendingUnknown = false;
      }
      rethrow;
    } on GatewayFailure catch (failure) {
      if (epoch != _scopeEpoch || endpoint != _endpoint || _cleanupPending) {
        rethrow;
      }
      throw GatewayFailure(
        failure.message,
        suspendVault: _pendingUnknown || failure.suspendVault,
        invalidateSession: failure.invalidateSession,
      );
    } catch (_) {
      if (epoch != _scopeEpoch || endpoint != _endpoint || _cleanupPending) {
        throw const GatewayFailure('原写入所属的会话已结束。');
      }
      throw const GatewayFailure('写入结果未确认，请查询原操作。', suspendVault: true);
    }
  }

  @override
  Future<List<PendingVaultOperation>> businessPendingInfo() async {
    final data = NativePendingOperation.parseList(
      nativeData(await _execute('businessPendingInfo', {})),
    );
    _pendingUnknown = data.any((item) => item.canRetry);
    return data;
  }

  @override
  Future<PendingVaultOperation> retryBusinessOperation(String id) async {
    if (!nativeIdentifier(id) || id.length > 64) {
      throw const GatewayFailure('原ID格式无效，未发送新意图。');
    }
    final item = NativePendingOperation.parse(
      nativeData(
        await _execute('retryBusinessOperation', {'id': id}, originalId: id),
        originalId: id,
      ),
    );
    if (item.id != id) throw const GatewayFailure('原事务ID改变，已拒绝。');
    return item;
  }

  @override
  Future<String> beginInitialization(
    String email,
    String password,
    String name,
  ) async {
    _require('beginInitialization');
    _require('restoreSession');
    if (_initializationId != null) {
      throw const GatewayFailure('已有原首机意图，不能另生成恢复码或ID。');
    }
    await _ensureDevice();
    final id = _newId();
    _initializationId = id;
    final result = await _execute('beginInitialization', {
      'email': email,
      'password': password,
      'name': name,
      'id': id,
    }, originalId: id);
    nativeData(result, originalId: id);
    final code = result['recoveryCode'];
    if (code is! String || code.isEmpty || code.length > 2048) {
      throw const GatewayFailure('原生未返回本次完整新恢复码；只能查询原初始化。');
    }
    return code;
  }

  @override
  Future<VaultSession> completeInitialization(String fullCodeReentry) async {
    if (fullCodeReentry.isEmpty || fullCodeReentry.length > 2048) {
      throw const GatewayFailure('请输入完整的新恢复码。');
    }
    nativeData(
      await _execute('completeInitialization', {
        'recoveryCode': fullCodeReentry,
      }),
      originalId: _initializationId,
    );
    final session = await restoreSession();
    _approvalVersion = 3;
    _initializationId = null;
    return session;
  }

  @override
  Future<String> queryInitialization() async {
    final data = nativeObject(
      nativeData(await _execute('queryInitialization', {})),
      '原初始化',
    );
    final state = data['state'];
    if (state is! String ||
        !{'none', 'absent', 'pending', 'complete'}.contains(state)) {
      throw const GatewayFailure('原初始化状态无效。');
    }
    if (state == 'none') _initializationId = null;
    return state;
  }

  @override
  Future<void> approve(ApprovalDraft draft) async {
    _require(_approvalOperation);
    if (_approvalPendingId != null) {
      throw const GatewayFailure('已有原审批事务；必须查询原PairID，不得替换短码或范围。');
    }
    if (_trusted == null || draft.roles.isEmpty || draft.roles.length > 16) {
      throw const GatewayFailure('需要可信设备及1–16项明确环境选择。');
    }
    final available = {
      for (final e in _trusted!.view.environments) e.id: e.role,
    };
    if (draft.roles.keys.any((id) => available[id] != AccessRole.admin)) {
      throw const GatewayFailure('只可批准本机已验管理权限的环境。');
    }
    final expiry = draft.lifetime == null
        ? '0'
        : (_now().toUtc().add(draft.lifetime!).millisecondsSinceEpoch ~/ 1000)
              .toString();
    final selections = [
      for (final choice in draft.roles.entries)
        NativeApprovalSelection(
          environmentId: choice.key,
          role: switch (choice.value) {
            AccessRole.readOnly => 'ro',
            AccessRole.readWrite => 'rw',
            AccessRole.admin => 'admin',
          },
          expiresAt: expiry,
        ),
    ];
    final epoch = _scopeEpoch, endpoint = _endpoint, version = _approvalVersion;
    bool sameScope() =>
        epoch == _scopeEpoch &&
        endpoint == _endpoint &&
        version == _approvalVersion &&
        !_cleanupPending;
    final code = Uint8List.fromList(ascii.encode(draft.code));
    _approvalPendingId = draft.pairingId;
    _approvalProgress = DeviceApprovalProgress(
      state: 'unknown',
      pairingId: draft.pairingId,
    );
    try {
      final result = await _platform(
        () => _approveUsingProvider(
          endpoint,
          version,
          draft.pairingId,
          code,
          selections,
        ),
        id: draft.pairingId,
      );
      if (!sameScope()) {
        throw const GatewayFailure('原审批所属的会话已结束，已丢弃晚到结果。');
      }
      final data = nativeObject(
        nativeData(result, originalId: draft.pairingId),
        '审批',
      );
      if (data['pairingId'] != draft.pairingId ||
          !{'approved', 'complete'}.contains(data['state'])) {
        throw const GatewayFailure('审批状态未确认，只能查询原PairID。');
      }
      _approvalProgress = _decodeApproval(data, original: draft.pairingId);
      if (data['state'] == 'complete') _approvalPendingId = null;
    } on NativeIntentFailure catch (failure) {
      if (!sameScope()) {
        throw const GatewayFailure('原审批所属的会话已结束，已丢弃晚到错误。');
      }
      if (const {
        'AUTH_CANCELLED',
        'AUTH_FAILED',
        'AUTH_UNAVAILABLE',
        'PROTECTED_KEYS_UNAVAILABLE',
        'BUSY',
        'LOCKED',
        'INVALID_COMMAND',
      }.contains(failure.code)) {
        _approvalPendingId = null;
        _approvalProgress = const DeviceApprovalProgress(state: 'none');
      }
      rethrow;
    } finally {
      code.fillRange(0, code.length, 0);
    }
  }

  DeviceApprovalProgress _decodeApproval(Object? value, {String? original}) {
    final data = nativeObject(value, '原审批状态');
    final state = data['state'], id = data['pairingId'];
    final sequence = data['sequence'] ?? 0;
    if (state is! String ||
        !{
          'none',
          'prepared',
          'unknown',
          'approved',
          'complete',
          'expired-pending',
        }.contains(state) ||
        sequence is! int ||
        sequence < 0 ||
        sequence > 9007199254740991 ||
        state != 'none' && (id is! String || !nativeIdentifier(id)) ||
        state != 'none' && original != null && id != original ||
        state == 'complete' && sequence == 0) {
      throw const GatewayFailure('原审批状态或ID无效，不能报告完成。', suspendVault: true);
    }
    return DeviceApprovalProgress(
      state: state,
      pairingId: id is String ? id : '',
      sequence: sequence,
    );
  }

  @override
  Future<DeviceApprovalProgress> queryApproval() async {
    final status = _decodeApproval(
      nativeData(await _execute(_approvalInfoOperation, {})),
      original: _approvalPendingId,
    );
    _approvalProgress = status;
    if (status.state == 'none' || status.state == 'complete') {
      _approvalPendingId = null;
    }
    return status;
  }

  @override
  Future<DeviceApprovalProgress> retryApproval(String originalPairingId) async {
    if (originalPairingId != _approvalProgress.pairingId ||
        !_approvalProgress.canRetry) {
      throw const GatewayFailure('只能续办已核验的原PairID。');
    }
    final status = _decodeApproval(
      nativeData(
        await _execute(_approvalRetryOperation, {
          'pairingId': originalPairingId,
        }, originalId: originalPairingId),
        originalId: originalPairingId,
      ),
      original: originalPairingId,
    );
    _approvalProgress = status;
    if (status.state == 'complete') _approvalPendingId = null;
    return status;
  }

  @override
  Future<void> cancelApproval(String originalPairingId) async {
    if (originalPairingId != _approvalProgress.pairingId ||
        !_approvalProgress.canCancel) {
      throw const GatewayFailure('仅原未POST prepared审批可取消。');
    }
    nativeData(
      await _execute(_approvalCancelOperation, {
        'pairingId': originalPairingId,
      }, originalId: originalPairingId),
    );
    _approvalProgress = const DeviceApprovalProgress(state: 'none');
    _approvalPendingId = null;
  }

  @override
  Future<List<AuthorizationRequest>> authorizationRequests() async =>
      throw const GatewayFailure('真实前台请求列表API尚未接通。');
  @override
  Future<void> revoke(String deviceId) async =>
      throw const GatewayFailure('设备撤销UI映射尚未验收，未执行撤销。');
  @override
  Future<void> logout() async {
    retireManagementResults();
    retireRecoveryResults();
    retirePendingPairingResults();
    _scopeEpoch++;
    _cleanupPending = true;
    _trusted = null;
    _approvalVersion = 0;
    nativeData(await _execute('logout', {}));
    _protectedDeviceExists = false;
    _deviceId = '';
    _checkpoint = 0;
    _initializationId = null;
    _approvalPendingId = null;
    _approvalProgress = const DeviceApprovalProgress(state: 'none');
    _pendingUnknown = false;
    _cleanupPending = false;
    _dagSelected = false;
    _managementOperation = const ManagementOperation(
      phase: ManagementPhase.idle,
    );
  }
}

/// 只读取最小公开实例身份与注册开关；HTTPS状态200本身不算验证成功。
class PublicConnectionGateway extends FailClosedGateway
    implements InstanceConnectionGateway {
  @override
  Future<InstanceDescriptor> inspectInstance(String endpoint) =>
      inspectHarmoniaInstance(endpoint);
}

Future<InstanceDescriptor> inspectHarmoniaInstance(
  String endpoint, {
  HttpClient Function()? clientFactory,
}) async {
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
  final client = (clientFactory?.call() ?? HttpClient())
    ..connectionTimeout = const Duration(seconds: 8);
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
