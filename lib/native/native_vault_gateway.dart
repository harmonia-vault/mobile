import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

import '../vault_controller.dart';
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
        NativeLocalProtectionPort {
  const MethodChannelGatewayPort();
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
        LocalProtectionGateway {
  NativeVaultGateway({
    required this.experimentalOptIn,
    this.productFixture = false,
    NativeGatewayPort? port,
    Set<String>? verifiedNativeOperations,
    Set<String>? verifiedPINOperations,
    DateTime Function()? now,
    Future<InstanceDescriptor> Function(String)? inspector,
  }) : _port = port ?? const MethodChannelGatewayPort(),
       _verifiedOperations = Set.unmodifiable(
         verifiedNativeOperations ?? _nativeEvidence,
       ),
       _verifiedPINOperations = Set.unmodifiable(
         verifiedPINOperations ?? _pinEvidence,
       ),
       _now = now ?? DateTime.now,
       _inspector = inspector ?? inspectHarmoniaInstance;
  final bool experimentalOptIn, productFixture;
  ProductFixtureConnection? _fixtureConnection;
  final NativeGatewayPort _port;
  final Set<String> _verifiedOperations;
  final Set<String> _verifiedPINOperations;
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
      _runtimeOperations.contains(operation) &&
      (_localProtection?.mode == LocalProtectionMode.pin
          ? _localProtection!.pinWorkflowReady &&
                !_localProtection!.upgradeRequired &&
                _localProtection!.systemCapability == 'NO_SYSTEM_AUTH' &&
                _verifiedPINOperations.contains(operation)
          : _systemStrong && _verifiedOperations.contains(operation));

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
  Set<String> get capabilities => Set.unmodifiable({
    if (_has('register')) 'registerAccount',
    if (_has('verifyEmail')) 'verifyEmail',
    if (_has('loginAccount')) 'loginAccount',
    if (_has('restoreSession') && _has('businessPendingInfo')) 'restoreSession',
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
    if (_approvalVersion != 0 && _has(_approvalOperation)) 'approveDevice',
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
    if (!_has(operation) ||
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
    _systemStrong = caps['systemStrongAuthentication'] == true;
    if (caps['appPINDeviceExists'] == true) _pinPreviouslyObserved = true;
    _protectedDeviceExists = caps['protectedDeviceExists'] == true;
    _runtimeOperations = Set.unmodifiable(operations.cast<String>());
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
    return projection.session;
  }

  @override
  Future<VaultSnapshot> pull() async {
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
