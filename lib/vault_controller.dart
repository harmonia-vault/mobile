import 'package:flutter/foundation.dart';

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
    required Map<String, AccessRole> roles,
    required this.lifetime,
  }) : roles = Map.unmodifiable(roles);
  final String code;
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
  static const reason = '可信配对、Go 同步桥和系统设备认证尚未接通。当前不能登录、读取或修改真实保险库。';
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

class VaultController extends ChangeNotifier {
  VaultController({required this.gateway});
  final VaultGateway gateway;
  bool _busy = false;
  String _endpoint = 'https://vault.example.invalid';
  String? _error;
  VaultSnapshot _snapshot = VaultSnapshot(
    checkpoint: 0,
    environments: const [],
    devices: const [],
  );
  ConnectionPhase _phase = ConnectionPhase.blocked;
  bool get previewMode => gateway.synthetic;
  bool get busy => _busy;
  String get endpoint => _endpoint;
  ConnectionPhase get phase => _phase;
  String? get error => _error;
  List<VaultEnvironment> get environments => _snapshot.environments;
  List<VaultDevice> get devices => _snapshot.devices;
  int get checkpoint => _snapshot.checkpoint;
  String get recoveryStatus => '恢复签名、封套和原子轮换尚未接通';
  bool get restrictedRecovery => false;
  void clearError() {
    _error = null;
    notifyListeners();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      await operation();
    } on GatewayFailure catch (failure) {
      _error = failure.message;
    } catch (_) {
      _error = '操作未完成。请保留当前状态并重新查询；未确认任何云端变更。';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _pull() async {
    final pulled = await gateway.pull();
    if (pulled.checkpoint < _snapshot.checkpoint) {
      throw const GatewayFailure('返回的检查点倒退，已拒绝更新。');
    }
    _snapshot = pulled;
    _phase = previewMode ? ConnectionPhase.preview : ConnectionPhase.online;
  }

  Future<void> reload() => _run(() async {
    _phase = ConnectionPhase.syncing;
    try {
      await _pull();
    } on GatewayFailure {
      _phase = ConnectionPhase.blocked;
      rethrow;
    }
  });

  Future<void> _mutate(PreviewMutation mutation) => _run(() async {
    if (!previewMode) throw const GatewayFailure(FailClosedGateway.reason);
    await gateway.submit(mutation);
    // 提交接受后重新拉取，界面从不先修改本地权威快照。
    await _pull();
  });

  String _environmentName(String name) {
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 120) {
      throw const GatewayFailure('环境名称需为 1–120 个字符。');
    }
    return clean;
  }

  Future<void> createEnvironment(String name) => _run(() async {
    if (!previewMode) throw const GatewayFailure(FailClosedGateway.reason);
    await gateway.submit(
      PreviewMutation(
        PreviewOperation.createEnvironment,
        name: _environmentName(name),
      ),
    );
    await _pull();
  });
  Future<void> renameEnvironment(String id, String name) => _run(() async {
    if (!previewMode) throw const GatewayFailure(FailClosedGateway.reason);
    await gateway.submit(
      PreviewMutation(
        PreviewOperation.renameEnvironment,
        environmentId: id,
        name: _environmentName(name),
      ),
    );
    await _pull();
  });
  Future<void> deleteEnvironment(String id) => _mutate(
    PreviewMutation(PreviewOperation.deleteEnvironment, environmentId: id),
  );
  Future<void> setVariable(String environmentId, String name, String value) =>
      _run(() async {
        if (!previewMode) throw const GatewayFailure(FailClosedGateway.reason);
        if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name) ||
            name.length > 255) {
          throw const GatewayFailure('变量名需以字母或下划线开头，只含字母、数字和下划线，最多 255 个字符。');
        }
        if (value.length > 16384 || value.contains('\u0000')) {
          throw const GatewayFailure('变量值过长或包含不支持的空字符。');
        }
        await gateway.submit(
          PreviewMutation(
            PreviewOperation.setVariable,
            environmentId: environmentId,
            name: name,
            value: value,
          ),
        );
        await _pull();
      });
  Future<void> deleteVariable(String environmentId, String name) => _mutate(
    PreviewMutation(
      PreviewOperation.deleteVariable,
      environmentId: environmentId,
      name: name,
    ),
  );

  Future<void> setEndpoint(String value) => _run(() async {
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
    // 更换端点不沿用旧账号缓存或信任，后续由受审计 Go 桥建立新状态。
    if (!previewMode) {
      _snapshot = VaultSnapshot(
        checkpoint: 0,
        environments: const [],
        devices: const [],
      );
      _phase = ConnectionPhase.blocked;
    }
  });
  Future<void> signIn(String email, String password) => _run(() async {
    throw const GatewayFailure('登录尚未接通，未发送邮箱或密码。请勿在实验界面输入真实凭据。');
  });
  Future<void> approveDevice(ApprovalDraft draft) => _run(() async {
    throw const GatewayFailure('SPAKE2、设备公钥绑定和签名授权尚未接通；短码未发送，未批准设备。');
  });
  Future<void> revokeDevice(String id) => _run(() async {
    throw const GatewayFailure('真实设备授权尚未接通，未执行撤销。请勿依赖合成预览撤销已公开的秘密。');
  });
  Future<void> beginRecovery() => _run(() async {
    throw const GatewayFailure('恢复密钥和受限会话尚未接通，未生成恢复码。');
  });
  Future<void> rotateRecovery(String completeReentry) => _run(() async {
    throw const GatewayFailure('绑定的一次性挑战、重输持钥证明和原子封套切换尚未接通，未轮换恢复码。');
  });
  Future<void> queryRecoveryStatus() => _run(() async {
    throw const GatewayFailure('恢复状态查询尚未接通，无法确认服务器轮换结果。');
  });
}
