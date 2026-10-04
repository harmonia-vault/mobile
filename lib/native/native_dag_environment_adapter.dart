import 'dart:convert';

import 'package:flutter/services.dart';

import '../dag_business/dag_environment_gateway.dart';
import '../recovery/recovery_gateway.dart';
import '../vault_controller.dart';
import 'native_dag_business_adapter.dart' show dagBusinessIdentifier;
import 'native_dag_recovery_adapter.dart';
import 'native_ui_contract.dart';

abstract interface class NativeDAGEnvironmentPort {
  Future<Map<String, Object?>> dagEnvironmentProfile();
  Future<Map<String, Object?>> executeDAGEnvironment(
    String endpoint,
    String operation,
    Map<String, String> fields,
    Uint8List name,
  );
}

const dagEnvironmentFields = <String, Set<String>>{
  'createDAGEnvironment': {'requestId', 'authorityEnvironmentId'},
  'renameDAGEnvironment': {'requestId', 'environmentId'},
  'rotateDAGEnvironment': {'requestId', 'environmentId'},
  'deleteDAGEnvironment': {'requestId', 'environmentId'},
  'pendingDAGEnvironments': {},
  'retryDAGEnvironment': {'requestId'},
};
Never _invalid() =>
    throw const GatewayFailure('DAG环境结果不符合固定合同，未确认原操作。', suspendVault: true);
Map<String, Object?> _object(Object? raw, Set<String> fields) {
  final m = nativeObject(raw, 'DAG环境');
  nativeFields(m, fields);
  return m;
}

void validateDAGEnvironmentIntent(
  String endpoint,
  String operation,
  Map<String, String> fields,
  Uint8List name,
) {
  final expected = dagEnvironmentFields[operation],
      uri = Uri.tryParse(endpoint);
  if (expected == null ||
      fields.length != expected.length ||
      fields.keys.any((k) => !expected.contains(k)) ||
      fields.values.any((v) => !dagBusinessIdentifier(v)) ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      name.length > 480 ||
      name.contains(0)) {
    throw const GatewayFailure('环境请求格式无效，未发送。');
  }
  String decoded;
  try {
    decoded = utf8.decode(name);
  } on FormatException {
    throw const GatewayFailure('环境名称不是有效UTF-8，未发送。');
  }
  final named =
      operation == 'createDAGEnvironment' ||
      operation == 'renameDAGEnvironment';
  if (named
      ? decoded.trim().isEmpty || decoded.trim().runes.length > 120
      : name.isNotEmpty) {
    throw const GatewayFailure('环境名称或续办输入无效，未发送。');
  }
  if (utf8
          .encode(
            jsonEncode({
              'version': 1,
              'endpoint': endpoint,
              'operation': operation,
              ...fields,
            }),
          )
          .length >
      4096) {
    throw const GatewayFailure('环境命令超过4096字节，未发送。');
  }
}

class NativeDAGEnvironmentAdapter implements NativeDAGEnvironmentPort {
  const NativeDAGEnvironmentAdapter();
  static const _channel = MethodChannel('org.harmoniavault/native/v1');
  Map<String, Object?> _decode(String? raw, int limit) {
    if (raw == null || utf8.encode(raw).length > limit) _invalid();
    try {
      return nativeObject(jsonDecode(raw), 'DAG环境');
    } on FormatException {
      _invalid();
    }
  }

  @override
  Future<Map<String, Object?>> dagEnvironmentProfile() async => _decode(
    await _channel.invokeMethod<String>('dagEnvironmentProfile'),
    8192,
  );
  @override
  Future<Map<String, Object?>> executeDAGEnvironment(
    String endpoint,
    String operation,
    Map<String, String> fields,
    Uint8List name,
  ) async {
    try {
      validateDAGEnvironmentIntent(endpoint, operation, fields, name);
      return _decode(
        await _channel.invokeMethod<String>('executeDAGEnvironment', {
          'command': jsonEncode({
            'version': 1,
            'endpoint': endpoint,
            'operation': operation,
            ...fields,
          }),
          'name': name,
        }),
        4 * 1024 * 1024,
      );
    } finally {
      name.fillRange(0, name.length, 0);
    }
  }
}

Set<String> decodeDAGEnvironmentProfile(Map<String, Object?> raw) {
  nativeFields(raw, {'version', 'profile', 'operations'});
  final ops = raw['operations'];
  if (raw['version'] != 1 ||
      raw['profile'] != dagRecoveryProfile ||
      ops is! List ||
      ops.length != dagEnvironmentOperations.length ||
      ops.any(
        (op) => op is! String || !dagEnvironmentOperations.contains(op),
      ) ||
      ops.toSet().length != ops.length ||
      ops.join(',') != (dagEnvironmentOperations.toList()..sort()).join(',')) {
    _invalid();
  }
  return Set.unmodifiable(ops.cast<String>());
}

DAGEnvironmentInfo _info(Object? raw) {
  final m = _object(raw, {
    'requestId',
    'operation',
    'environmentId',
    'sequence',
    'applied',
  });
  final seq = dagDecimal(m['sequence'], safe: true);
  if (!dagBusinessIdentifier(m['requestId']) ||
      !dagBusinessIdentifier(m['environmentId']) ||
      !{'create', 'rename', 'rotate', 'delete'}.contains(m['operation']) ||
      m['applied'] is! bool ||
      m['applied'] == true && seq == '0') {
    _invalid();
  }
  return DAGEnvironmentInfo(
    requestId: m['requestId'] as String,
    operation: m['operation'] as String,
    environmentId: m['environmentId'] as String,
    sequence: seq,
    applied: m['applied'] as bool,
  );
}

DAGEnvironmentReply decodeDAGEnvironment(
  String operation,
  Map<String, Object?> raw, {
  String? originalId,
  String? environmentId,
}) {
  if (!dagEnvironmentFields.containsKey(operation) || raw['ok'] is! bool) {
    _invalid();
  }
  final ok = raw['ok'] as bool;
  nativeFields(raw, {
    'version',
    'profile',
    'operation',
    'ok',
    'trustedDevice',
    'data',
    if (!ok) 'error',
  });
  if (raw['version'] != 1 ||
      raw['profile'] != dagRecoveryProfile ||
      raw['operation'] != operation ||
      raw['trustedDevice'] != (ok && operation != 'pendingDAGEnvironments')) {
    _invalid();
  }
  if (operation == 'pendingDAGEnvironments') {
    if (!ok) _invalid();
    final data = _object(raw['data'], {'pending', 'trustedDevice'}),
        rows = data['pending'];
    if (data['trustedDevice'] != false || rows is! List || rows.length > 32) {
      _invalid();
    }
    final pending = rows.map(_info).toList();
    if (pending.map((r) => r.requestId).toSet().length != pending.length) {
      _invalid();
    }
    return DAGEnvironmentReply.pending(pending);
  }
  final data = _object(
    raw['data'],
    ok ? {'environment', 'source'} : {'original', 'trustedDevice'},
  );
  final info = _info(data[ok ? 'environment' : 'original']);
  final expected = {
    'createDAGEnvironment': 'create',
    'renameDAGEnvironment': 'rename',
    'rotateDAGEnvironment': 'rotate',
    'deleteDAGEnvironment': 'delete',
  }[operation];
  if (originalId == null ||
      info.requestId != originalId ||
      expected != null && info.operation != expected ||
      environmentId != null && info.environmentId != environmentId) {
    _invalid();
  }
  if (!ok) {
    final error = _object(raw['error'], {'code', 'retryOriginal'});
    if (error['code'] != 'ORIGINAL_RETRY_REQUIRED' ||
        error['retryOriginal'] != true ||
        data['trustedDevice'] != false ||
        info.applied) {
      _invalid();
    }
    return DAGEnvironmentReply.original(info);
  }
  if (!info.applied) _invalid();
  final source = decodeDAGTrustedSource(data['source']);
  if (int.parse(info.sequence) > source.snapshot.checkpoint) _invalid();
  return DAGEnvironmentReply.applied(info, source);
}
