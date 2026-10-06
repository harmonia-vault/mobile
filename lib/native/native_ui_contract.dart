import 'dart:convert';

import '../vault_controller.dart';

/// 原生只返回公开业务字段；错误不带原包、服务端消息或输入秘密。
class NativeIntentFailure extends GatewayFailure {
  NativeIntentFailure(this.code, {this.retrySameId = false, this.id})
    : super(
        _messages[code] ?? '原生操作未完成；没有确认云端或本机变更。',
        suspendVault:
            {
              'PENDING',
              'GO_OR_KEYSTORE_REJECTED',
              'NOT_TRUSTED',
              'TRUST_INVALIDATED',
              'CLOSED',
            }.contains(code) ||
            retrySameId &&
                id != null &&
                !const {
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
                }.contains(code),
        invalidateSession: code == 'TRUST_INVALIDATED' || code == 'CLOSED',
      );
  final String code;
  final bool retrySameId;
  final String? id;
  bool get trustInvalidated => code == 'TRUST_INVALIDATED' || code == 'CLOSED';
  static const _messages = {
    'PIN_CANCELLED': '已取消本次PIN输入，未批准操作。',
    'PIN_AUTH_FAILED': '本机PIN认证失败；请按持久限流状态等待后重试。',
    'PIN_BLOCKED': '本机PIN保护暂不可用；不会切换或降级认证方式。',
    'PIN_UPGRADE_REQUIRED': '系统认证现已可用，PIN模式已持久关闭。当前仅支持本地退出并重新授权新设备。',
    'LOCAL_PROTECTION_STATE': '本机保护状态无效或残留冲突；不能读取旧钥匙或自动初始化。',
    'LOCAL_PROTECTION_PERSISTENCE': '本机安全状态保存或清理未确认，不能报告操作成功。',
    'UNSUPPORTED': '本平台尚未接通此本机保护入口。',
    'AUTH_CANCELLED': '已取消系统认证，未批准本次操作。',
    'AUTH_FAILED': '系统认证失败，未批准本次操作；不会降级到 PIN。',
    'AUTH_UNAVAILABLE': '系统无法提供强认证；PIN 密钥保护尚未开放。',
    'PROTECTED_KEYS_UNAVAILABLE': '设备钥匙不可用，不能访问保险库。',
    'GO_OR_KEYSTORE_REJECTED': '原生密钥或保存步骤未完成；请先查询原操作。',
    'PENDING': '结果未确认；只能查询或续办原操作 ID，不能重新提交新意图。',
    'ID_CONFLICT': '原操作 ID 与事务冲突，已拒绝替换。',
    'UNAUTHORIZED': '当前环境授权不允许此操作。',
    'NOT_TRUSTED': '本机尚未获得可信设备授权。',
    'TRUST_INVALIDATED': '设备授权已失效，保险库内容已关闭。',
    'BUSY': '已有系统认证或原生操作正在进行。',
    'LOCKED': '本机安全适配器已锁定。',
    'CLOSED': '本机可信会话已关闭。',
    'REJECTED': '原生拒绝此操作，未确认任何修改。',
    'ACCOUNT_EXISTS': '此邮箱已注册或正在注册，请登录或完成邮箱验证。',
    'REGISTRATION_DISABLED': '服务器已关闭注册，请联系管理员。',
    'EMAIL_INVALID': '邮箱格式不正确，请检查后重试。',
    'EMAIL_DELIVERY_FAILED': '验证码邮件发送失败，请联系服务器管理员。',
    'EMAIL_UNAVAILABLE': '服务器邮件服务不可用，请联系管理员。',
    'EMAIL_VERIFICATION_REQUIRED': '邮箱尚未验证，请先完成邮箱验证。',
    'ACCOUNT_CHANGED': '账号状态已改变，请返回登录后重试。',
    'LOGIN_FAILED': '登录失败，请检查邮箱、密码，并确认已完成邮箱验证。',
    'NETWORK_ERROR': '连接未完成，请检查网络和服务器地址后重试。',
    'SERVER_RESPONSE_INVALID': '服务器响应无法识别，请确认客户端和服务器均已更新。',
    'REQUEST_RATE_LIMITED': '请求过于频繁，请稍后重试。',
    'SERVER_UNAVAILABLE': '服务器暂时不可用，请稍后重试或联系管理员。',
    'ACCOUNT_REQUEST_FAILED': '账号操作未完成，请重试或联系服务器管理员。',
    'EMAIL_CODE_INVALID': '验证码不正确，请重新输入八位字母数字。最多可尝试 5 次。',
    'EMAIL_CODE_EXPIRED': '验证码已过期，请重新发送。',
    'EMAIL_CODE_EXHAUSTED': '已达到 5 次尝试上限，请重新发送验证码。',
  };
}

Object? nativeData(Map<String, Object?> result, {String? originalId}) {
  if (result['version'] != 1 ||
      result['experimental'] != true ||
      result['ok'] is! bool) {
    throw const GatewayFailure('原生结果版本或类型不正确，已拒绝。');
  }
  if (result['ok'] != true) {
    final code = result['code'];
    if (code == 'REGISTRATION_EXPIRED') {
      throw const RegistrationExpiredFailure();
    }
    if (code == 'EMAIL_RATE_LIMITED') {
      final seconds = result['retryAfterSeconds'];
      if (seconds is! int || seconds < 1 || seconds > 86400) {
        throw const GatewayFailure('邮件发送等待时间无效，请稍后重试。');
      }
      throw EmailRateLimitFailure(seconds);
    }
    if (code is! String || !RegExp(r'^[A-Z_]{1,64}$').hasMatch(code)) {
      throw const GatewayFailure('原生失败类别无效，未确认操作。');
    }
    throw NativeIntentFailure(
      code,
      retrySameId: result['retrySameId'] == true,
      id: originalId,
    );
  }
  return result['data'];
}

Map<String, Object?> nativeObject(Object? value, String description) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw GatewayFailure('$description结果不完整，已拒绝。');
  }
  return Map<String, Object?>.from(value);
}

void nativeFields(Map<String, Object?> value, Set<String> fields) {
  if (value.length != fields.length ||
      value.keys.any((key) => !fields.contains(key))) {
    throw const GatewayFailure('原生公开结果字段不符合固定合同，已拒绝。');
  }
}

bool nativeIdentifier(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);

String nativeGeneration(Object? value) {
  if (value is! String ||
      !RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(value) ||
      BigInt.parse(value) > BigInt.parse('18446744073709551615')) {
    throw const GatewayFailure('原生账号代际无效，已拒绝。');
  }
  return value;
}

AccountAuthentication decodeAccountAuthentication(Object? value) {
  final data = nativeObject(value, '账号登录');
  nativeFields(data, {'authenticated', 'trustedDevice'});
  if (data['authenticated'] != true || data['trustedDevice'] != false) {
    throw const GatewayFailure('登录结果不能证明设备可信，已拒绝错误结果。');
  }
  return const AccountAuthentication(authenticated: true, trustedDevice: false);
}

class NativeRegistration {
  const NativeRegistration(
    this.accountId,
    this.accountGeneration,
    this.verificationRequired,
  );
  final String accountId, accountGeneration;
  final bool verificationRequired;
  static NativeRegistration parse(Object? value) {
    final data = nativeObject(value, '注册');
    nativeFields(data, {
      'accountId',
      'accountGeneration',
      'verificationRequired',
    });
    final account = data['accountId'];
    if (account is! String ||
        !nativeIdentifier(account) ||
        data['verificationRequired'] is! bool) {
      throw const GatewayFailure('原生注册结果不完整，不能继续初始化。');
    }
    return NativeRegistration(
      account,
      nativeGeneration(data['accountGeneration']),
      data['verificationRequired'] as bool,
    );
  }
}

VaultSnapshot decodeNativeView(Object? value) {
  final data = nativeObject(value, '保险库视图');
  nativeFields(data, {
    'checkpoint',
    'deviceId',
    'experimental',
    'environments',
  });
  final sequence = data['checkpoint'];
  final device = data['deviceId'];
  final environments = data['environments'];
  if (data['experimental'] != true ||
      sequence is! int ||
      sequence < 0 ||
      sequence > 9007199254740991 ||
      device is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(device) ||
      environments is! List) {
    throw const GatewayFailure('原生已验视图字段无效，未显示保险库。');
  }
  final ids = <String>{};
  final decoded = <VaultEnvironment>[];
  for (final item in environments) {
    final env = nativeObject(item, '环境');
    nativeFields(env, {'id', 'name', 'role', 'variables'});
    final id = env['id'];
    final name = env['name'];
    final values = env['variables'];
    final role = switch (env['role']) {
      'RO' => AccessRole.readOnly,
      'RW' => AccessRole.readWrite,
      'Admin' => AccessRole.admin,
      _ => null,
    };
    if (id is! String ||
        !nativeIdentifier(id) ||
        !ids.add(id) ||
        name is! String ||
        name.isEmpty ||
        name.runes.length > 120 ||
        name.contains('\u0000') ||
        role == null ||
        values is! Map) {
      throw const GatewayFailure('原生环境范围或角色无效，未显示保险库。');
    }
    final variables = <VaultVariable>[];
    for (final entry in values.entries) {
      final key = entry.key, text = entry.value;
      if (key is! String ||
          text is! String ||
          !RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(key) ||
          key.toUpperCase().startsWith('__HARMONIA_') ||
          text.contains('\u0000') ||
          utf8.encode(text).length > 65536) {
        throw const GatewayFailure('原生变量字段无效，未显示保险库。');
      }
      variables.add(VaultVariable(name: key, value: text));
    }
    variables.sort((a, b) => a.name.compareTo(b.name));
    decoded.add(
      VaultEnvironment(id: id, name: name, role: role, variables: variables),
    );
  }
  return VaultSnapshot(
    checkpoint: sequence,
    environments: decoded,
    devices: const [],
  );
}

class NativeTrustedProjection {
  const NativeTrustedProjection(this.session, this.deviceId, this.view);
  final VaultSession session;
  final String deviceId;
  final VaultSnapshot view;
  static NativeTrustedProjection parse(Object? value) {
    final data = nativeObject(value, '可信设备恢复');
    nativeFields(data, {
      'trustedDevice',
      'accountId',
      'accountGeneration',
      'deviceId',
      'view',
    });
    final account = data['accountId'];
    final device = data['deviceId'];
    if (data['trustedDevice'] != true ||
        account is! String ||
        !nativeIdentifier(account) ||
        device is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(device)) {
      throw const GatewayFailure('缺少原生已验可信设备投影，不能进入保险库。');
    }
    final inner = nativeObject(data['view'], '可信设备视图');
    if (inner['deviceId'] != device) {
      throw const GatewayFailure('可信设备与视图绑定不一致，已拒绝。');
    }
    final view = decodeNativeView(inner);
    return NativeTrustedProjection(
      VaultSession(
        SessionStage.trusted,
        accountId: account,
        accountGeneration: nativeGeneration(data['accountGeneration']),
      ),
      device,
      view,
    );
  }
}

class NativePendingOperation extends PendingVaultOperation {
  const NativePendingOperation({
    required super.id,
    required super.operation,
    required super.environmentId,
    required super.state,
    required super.sequence,
    required super.applied,
  });
  static NativePendingOperation parse(Object? value) {
    final data = nativeObject(value, '原事务');
    const fields = {
      'id',
      'operation',
      'environmentId',
      'state',
      'sequence',
      'applied',
    };
    final id = data['id'], operation = data['operation'];
    final env = data['environmentId'], state = data['state'];
    final seq = data['sequence'], applied = data['applied'];
    if (data.keys.toSet().difference(fields).isNotEmpty ||
        data.length != fields.length ||
        id is! String ||
        !nativeIdentifier(id) ||
        id.length > 64 ||
        operation is! String ||
        !{'put', 'delete', 'create', 'rename', 'rotate'}.contains(operation) ||
        env is! String ||
        !nativeIdentifier(env) ||
        state is! String ||
        !{
          'unknown',
          'accepted-not-applied',
          'applied',
          'canceled',
        }.contains(state) ||
        seq is! int ||
        seq < 0 ||
        seq > 9007199254740991 ||
        applied is! bool ||
        applied != (state == 'applied') ||
        state == 'accepted-not-applied' && seq == 0 ||
        state == 'canceled' && seq != 0) {
      throw const GatewayFailure('原事务元数据无效，已拒绝；不会生成新 ID。');
    }
    return NativePendingOperation(
      id: id,
      operation: operation,
      environmentId: env,
      state: state,
      sequence: seq,
      applied: applied,
    );
  }

  static List<NativePendingOperation> parseList(Object? value) {
    if (value is! List || value.length > 64) {
      throw const GatewayFailure('原事务列表无效，已拒绝。');
    }
    final ids = <String>{};
    final items = value.map(parse).toList();
    if (items.any((item) => !ids.add(item.id))) {
      throw const GatewayFailure('原事务 ID 重复，已拒绝。');
    }
    return List.unmodifiable(items);
  }
}
