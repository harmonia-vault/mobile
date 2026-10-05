import 'dart:convert';

import 'package:flutter/services.dart';

import '../pairing/pending_pairing_gateway.dart';
import '../pairing/pending_pairing_presentation.dart';
import '../vault_controller.dart';
import 'native_ui_contract.dart';

const pendingPairingOperations = {'pendingPairingRequestsV5'};

abstract interface class NativePendingPairingsPort {
  Future<Map<String, Object?>> executePendingPairings(
    String endpoint,
    String operation,
  );
}

class NativePendingPairingsAdapter implements NativePendingPairingsPort {
  const NativePendingPairingsAdapter();
  static const _channel = MethodChannel('org.harmoniavault/native/v1');
  @override
  Future<Map<String, Object?>> executePendingPairings(
    String endpoint,
    String operation,
  ) async {
    final uri = Uri.tryParse(endpoint);
    if (!pendingPairingOperations.contains(operation) ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const GatewayFailure('前台请求读取不符合固定合同，未发送。');
    }
    final command = jsonEncode({
      'version': 1,
      'endpoint': endpoint,
      'operation': operation,
    });
    if (utf8.encode(command).length > 4096) {
      throw const GatewayFailure('前台请求读取超过长度上限，未发送。');
    }
    final raw = await _channel.invokeMethod<String>('executePendingPairings', {
      'command': command,
    });
    if (raw == null || utf8.encode(raw).length > 65536) {
      throw const GatewayFailure('前台请求结果缺失或过大，未确认。');
    }
    try {
      return nativeObject(jsonDecode(raw), '前台请求');
    } on FormatException {
      throw const GatewayFailure('前台请求结果编码无效，未确认。');
    }
  }
}

Never _invalid() => throw const GatewayFailure('前台请求结果不符合固定合同，未显示提示。');
String _decimal(Object? raw) {
  if (raw is! String ||
      !RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(raw) ||
      BigInt.parse(raw) > BigInt.parse('18446744073709551615')) {
    _invalid();
  }
  return raw;
}

String _id(Object? raw) {
  if (raw is! String || !nativeIdentifier(raw)) _invalid();
  return raw;
}

Map<String, Object?> _fields(Object? raw, Set<String> fields) {
  final value = nativeObject(raw, '前台请求');
  nativeFields(value, fields);
  return value;
}

PendingPairingSnapshot decodePendingPairings(
  String operation,
  Map<String, Object?> raw,
) {
  nativeFields(raw, {'version', 'operation', 'ok', 'data'});
  if (!pendingPairingOperations.contains(operation) ||
      raw['version'] != 1 ||
      raw['operation'] != operation ||
      raw['ok'] != true) {
    _invalid();
  }
  final data = _fields(raw['data'], {
    'accountId',
    'accountGeneration',
    'approverDeviceId',
    'certificateVersion',
    'capabilities',
    'requests',
    'authoritativeForApproval',
  });
  const version = '5';
  const expectedCapability = 'issuer-recovery-dag-v1';
  final caps = data['capabilities'], rows = data['requests'];
  if (data['certificateVersion'] != version ||
      data['authoritativeForApproval'] != false ||
      caps is! List ||
      caps.length != 1 ||
      caps.single != expectedCapability ||
      rows is! List ||
      rows.length > 64) {
    _invalid();
  }
  final seen = <String>{}, requests = <PendingPairingHint>[];
  for (final row in rows) {
    final r = _fields(row, {
      'idempotencyKey',
      'initiatorDeviceId',
      'state',
      'expiresAt',
    });
    final id = _id(r['idempotencyKey']), device = _id(r['initiatorDeviceId']);
    final expiry = BigInt.parse(_decimal(r['expiresAt']));
    if (!seen.add(id) ||
        !{'pending', 'approved'}.contains(r['state']) ||
        expiry > BigInt.from(8640000000000)) {
      _invalid();
    }
    requests.add(
      PendingPairingHint(
        pairingId: id,
        initiatorDeviceId: device,
        state: r['state'] == 'pending'
            ? PendingPairingState.pending
            : PendingPairingState.approved,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          expiry.toInt() * 1000,
          isUtc: true,
        ),
      ),
    );
  }
  return PendingPairingSnapshot(
    accountId: _id(data['accountId']),
    accountGeneration: _decimal(data['accountGeneration']),
    approverDeviceId: _id(data['approverDeviceId']),
    certificateVersion: version,
    capabilities: [expectedCapability],
    requests: requests,
  );
}
