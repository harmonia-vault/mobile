import 'dart:convert';

import 'package:flutter/services.dart';

import '../dag_business/dag_business_gateway.dart';
import '../recovery/recovery_gateway.dart';
import '../vault_controller.dart';
import 'native_dag_recovery_adapter.dart';
import 'native_ui_contract.dart';

abstract interface class NativeDAGBusinessPort {
  Future<Map<String, Object?>> dagBusinessProfile();
  Future<Map<String, Object?>> executeDAGBusiness(
    String endpoint,
    String operation,
    Map<String, String> fields,
    Uint8List value,
  );
}

const dagBusinessFields = <String, Set<String>>{
  'putDAGVariable': {'requestId', 'environmentId', 'name'},
  'deleteDAGVariable': {'requestId', 'environmentId', 'name'},
  'pendingDAGWrites': {},
  'retryDAGWrite': {'requestId'},
};

Never _invalid() =>
    throw const GatewayFailure('DAG 业务投影不符合固定合同，未确认原操作。', suspendVault: true);

Map<String, Object?> _object(Object? value, Set<String> fields) {
  final m = nativeObject(value, 'DAG业务');
  nativeFields(m, fields);
  return m;
}

bool dagBusinessIdentifier(Object? value) =>
    value is String &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$').hasMatch(value);

void validateDAGBusinessIntent(
  String endpoint,
  String operation,
  Map<String, String> fields,
  Uint8List value,
) {
  final expected = dagBusinessFields[operation], uri = Uri.tryParse(endpoint);
  if (expected == null ||
      fields.length != expected.length ||
      fields.keys.any((k) => !expected.contains(k)) ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      expected.contains('requestId') &&
          !dagBusinessIdentifier(fields['requestId']) ||
      expected.contains('environmentId') &&
          !dagBusinessIdentifier(fields['environmentId']) ||
      expected.contains('name') &&
          (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$')
                  .hasMatch(fields['name']!) ||
              fields['name']!.toUpperCase().startsWith('__HARMONIA_')) ||
      operation != 'putDAGVariable' && value.isNotEmpty ||
      value.length > 65536 ||
      value.contains(0)) {
    throw const GatewayFailure('DAG业务意图格式或长度无效，未发送。');
  }
  try {
    utf8.decode(value);
  } on FormatException {
    throw const GatewayFailure('DAG变量值不是有效UTF-8，未发送。');
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
    throw const GatewayFailure('DAG业务请求超过4096个UTF-8字节，未发送。');
  }
}

class NativeDAGBusinessAdapter implements NativeDAGBusinessPort {
  const NativeDAGBusinessAdapter();
  static const _channel = MethodChannel('org.harmoniavault/native/v1');
  Map<String, Object?> _decode(String? result, int limit) {
    if (result == null || utf8.encode(result).length > limit) _invalid();
    try {
      return nativeObject(jsonDecode(result), 'DAG业务');
    } on FormatException {
      _invalid();
    }
  }

  @override
  Future<Map<String, Object?>> dagBusinessProfile() async =>
      _decode(await _channel.invokeMethod<String>('dagBusinessProfile'), 8192);
  @override
  Future<Map<String, Object?>> executeDAGBusiness(
    String endpoint,
    String operation,
    Map<String, String> fields,
    Uint8List value,
  ) async {
    try {
      validateDAGBusinessIntent(endpoint, operation, fields, value);
      return _decode(
        await _channel.invokeMethod<String>('executeDAGBusiness', {
          'command': jsonEncode({
            'version': 1,
            'endpoint': endpoint,
            'operation': operation,
            ...fields,
          }),
          'value': value,
        }),
        4 * 1024 * 1024,
      );
    } finally {
      value.fillRange(0, value.length, 0);
    }
  }
}

Set<String> decodeDAGBusinessProfile(Map<String, Object?> raw) {
  nativeFields(raw, {'version', 'profile', 'operations'});
  final ops = raw['operations'];
  if (raw['version'] != 1 ||
      raw['profile'] != dagRecoveryProfile ||
      ops is! List ||
      ops.length != dagBusinessOperations.length ||
      ops.any((op) => op is! String || !dagBusinessOperations.contains(op)) ||
      ops.toSet().length != ops.length ||
      ops.join(',') != (dagBusinessOperations.toList()..sort()).join(',')) {
    _invalid();
  }
  return Set.unmodifiable(ops.cast<String>());
}

List<String> _sequences(Object? raw, int accepted) {
  if (raw is! List || raw.length != 1) _invalid();
  final sequence = dagDecimal(raw.single, safe: true);
  if ((accepted == 1) != (sequence != '0')) _invalid();
  return List.unmodifiable([sequence]);
}

DAGPendingWrite _pending(Object? value) {
  final m = _object(value, {
    'requestId',
    'operation',
    'environmentId',
    'total',
    'accepted',
    'applied',
    'canceled',
    'sequences',
  });
  if (!dagBusinessIdentifier(m['requestId']) ||
      !dagBusinessIdentifier(m['environmentId']) ||
      !{'put', 'delete'}.contains(m['operation']) ||
      m['total'] != 1 ||
      m['accepted'] is! int ||
      !{0, 1}.contains(m['accepted']) ||
      m['applied'] != false ||
      m['canceled'] is! bool) {
    _invalid();
  }
  return DAGPendingWrite(
    requestId: m['requestId'] as String,
    operation: m['operation'] as String,
    environmentId: m['environmentId'] as String,
    accepted: m['accepted'] as int,
    canceled: m['canceled'] as bool,
    sequences: _sequences(m['sequences'], m['accepted'] as int),
  );
}

DAGBusinessReply decodeDAGBusiness(
  String operation,
  Map<String, Object?> raw, {
  String? originalId,
}) {
  if (!dagBusinessFields.containsKey(operation) || raw['ok'] is! bool) {
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
      raw['trustedDevice'] != (ok && operation != 'pendingDAGWrites')) {
    _invalid();
  }
  if (!ok) {
    if (operation == 'pendingDAGWrites') _invalid();
    final error = _object(raw['error'], {'code', 'retryOriginal'});
    final data = _object(raw['data'], {'original', 'trustedDevice'});
    if (error['code'] != 'ORIGINAL_RETRY_REQUIRED' ||
        error['retryOriginal'] != true ||
        data['trustedDevice'] != false) {
      _invalid();
    }
    final original = _pending(data['original']);
    if (originalId == null ||
        original.requestId != originalId ||
        original.canceled) {
      _invalid();
    }
    return DAGBusinessReply.original(original);
  }
  if (operation == 'pendingDAGWrites') {
    final data = _object(raw['data'], {'pending', 'trustedDevice'});
    final rows = data['pending'];
    if (data['trustedDevice'] != false || rows is! List || rows.length > 32) {
      _invalid();
    }
    final pending = rows.map(_pending).toList();
    if (pending.map((p) => p.requestId).toSet().length != pending.length) {
      _invalid();
    }
    return DAGBusinessReply.pending(pending);
  }
  final data = _object(raw['data'], {'write', 'source'});
  final write = _object(data['write'], {
    'requestId',
    'total',
    'accepted',
    'applied',
    'sequences',
  });
  if (!dagBusinessIdentifier(write['requestId']) ||
      originalId == null ||
      write['requestId'] != originalId ||
      write['total'] != 1 ||
      write['accepted'] != 1 ||
      write['applied'] != true) {
    _invalid();
  }
  final sequences = _sequences(write['sequences'], 1);
  final source = decodeDAGTrustedSource(data['source']);
  if (int.parse(sequences.single) > source.snapshot.checkpoint) _invalid();
  return DAGBusinessReply.applied(
    DAGWriteReceipt(originalId, sequences),
    source,
  );
}
