import 'dart:convert';

import 'package:flutter/services.dart';

import '../recovery/recovery_gateway.dart';
import '../recovery/recovery_presentation.dart';
import '../vault_controller.dart';
import 'native_ui_contract.dart';

/// 独立入口，不复用旧 authority 的十四方法。
abstract interface class NativeDAGRecoveryPort {
  Future<Map<String, Object?>> executeDAGRecovery(
    String endpoint,
    String operation,
    Map<String, String> fields,
    Uint8List completeCode,
  );
}

const dagRecoveryFields = <String, Set<String>>{
  'openDAGRecoveryOwner': {'email', 'password'},
  'dagRecoveryOwnerInfo': {},
  'dagRecoveryPreparationInfo': {},
  'dagRecoveryPendingInfo': {},
  'beginDAGRecoveryTransition': {},
  'sealDAGRecoveryTransition': {},
  'retryDAGRecoveryTransition': {},
  'queryDAGRecoveryOriginal': {},
  'cancelDAGRecoveryOwner': {},
  'dagRecoveredEnrollmentChoices': {},
  'sealDAGRecoveredDevice': {
    'expectedSequence',
    'recoveryHeadHash',
    'selections',
  },
  'retryDAGRecoveredDevice': {'operationId', 'contentHash'},
  'dagRecoveredDeviceInfo': {},
  'applyDAGRecoveredDevice': {'operationId', 'contentHash'},
  'restoreDAGRecoveredDevice': {},
  'pullDAGRecoveredDevice': {},
};
const _codeOperations = {
  'openDAGRecoveryOwner',
  'sealDAGRecoveryTransition',
  'queryDAGRecoveryOriginal',
};
const _trustedOperations = {
  'applyDAGRecoveredDevice',
  'restoreDAGRecoveredDevice',
  'pullDAGRecoveredDevice',
};

class NativeDAGRecoveryAdapter implements NativeDAGRecoveryPort {
  const NativeDAGRecoveryAdapter();
  static const _channel = MethodChannel('org.harmoniavault/native/v1');
  @override
  Future<Map<String, Object?>> executeDAGRecovery(
    String endpoint,
    String operation,
    Map<String, String> fields,
    Uint8List completeCode,
  ) async {
    try {
      final expected = dagRecoveryFields[operation];
      final uri = Uri.tryParse(endpoint);
      if (expected == null ||
          fields.length != expected.length ||
          fields.keys.any((key) => !expected.contains(key)) ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (_codeOperations.contains(operation)
              ? completeCode.isEmpty || completeCode.length > 512
              : completeCode.isNotEmpty)) {
        throw const GatewayFailure('恢复意图不符合固定原生合同，未发送。');
      }
      final command = jsonEncode({
        'version': 1,
        'endpoint': endpoint,
        'operation': operation,
        ...fields,
      });
      if (utf8.encode(command).length > 32768) {
        throw const GatewayFailure('恢复请求超过原生长度上限，未发送。');
      }
      final result = await _channel.invokeMethod<String>('executeDAGRecovery', {
        'command': command,
        'completeCode': completeCode,
      });
      if (result == null || result.length > 4 * 1024 * 1024) {
        throw const GatewayFailure('恢复原生结果缺失或过大，未确认操作。');
      }
      return nativeObject(jsonDecode(result), '恢复');
    } on FormatException {
      throw const GatewayFailure('恢复原生结果编码无效，未确认操作。');
    } finally {
      completeCode.fillRange(0, completeCode.length, 0);
    }
  }
}

Never _invalid() => throw const GatewayFailure('恢复原生结果不符合固定合同，未确认操作。');
Map<String, Object?> _object(Object? v, Set<String> fields) {
  final m = nativeObject(v, '恢复');
  nativeFields(m, fields);
  return m;
}

String _string(Object? v) {
  if (v is! String) _invalid();
  return v;
}

bool _bool(Object? v) {
  if (v is! bool) _invalid();
  return v;
}

String _id(Object? v, {bool empty = false}) {
  final s = _string(v);
  if (!(empty && s.isEmpty) && !nativeIdentifier(s)) _invalid();
  return s;
}

String _hash(Object? v, {bool empty = false}) {
  final s = _string(v);
  if (!(empty && s.isEmpty) && !RegExp(r'^[a-f0-9]{64}$').hasMatch(s)) {
    _invalid();
  }
  return s;
}

String dagDecimal(Object? value, {bool positive = false, bool safe = false}) {
  final s = _string(value);
  if (!RegExp(r'^(0|[1-9][0-9]{0,19})$').hasMatch(s)) _invalid();
  final n = BigInt.parse(s);
  if (n > BigInt.parse(safe ? '9007199254740991' : '18446744073709551615') ||
      positive && n == BigInt.zero) {
    _invalid();
  }
  return s;
}

void _header(Map<String, Object?> m, {bool trusted = false}) {
  if (m['version'] != 1 ||
      m['profile'] != dagRecoveryProfile ||
      m['trustedDevice'] != trusted) {
    _invalid();
  }
}

RecoveryOwner _owner(Object? raw) {
  final m = _object(raw, {
    'recoveryGeneration',
    'sequence',
    'environments',
    'rotationRequired',
    'trustedDevice',
    'expiresAt',
  });
  final count = m['environments'];
  if (m['trustedDevice'] != false ||
      count is! int ||
      count < 0 ||
      count > 256) {
    _invalid();
  }
  return RecoveryOwner(
    dagDecimal(m['recoveryGeneration'], positive: true),
    dagDecimal(m['sequence'], positive: true, safe: true),
    count,
    _bool(m['rotationRequired']),
    dagDecimal(m['expiresAt'], positive: true),
  );
}

RecoveryPreparation _preparation(Object? raw) {
  final m = _object(raw, {
    'version',
    'profile',
    'state',
    'operationId',
    'phase',
    'needsOriginalOwner',
    'trustedDevice',
  });
  _header(m);
  final state = _string(m['state']),
      id = _id(m['operationId'], empty: true),
      phase = _string(m['phase']),
      needs = _bool(m['needsOriginalOwner']);
  if (state == 'none') {
    if (id.isNotEmpty || phase.isNotEmpty || needs) _invalid();
  } else if (state != 'preparation-pending' ||
      id.isEmpty ||
      !{'intent', 'challenged'}.contains(phase) ||
      !needs) {
    _invalid();
  }
  return RecoveryPreparation(state, id, phase, needs);
}

RecoveryPending _pending(Object? raw) {
  final m = _object(raw, {
    'version',
    'profile',
    'state',
    'operationId',
    'kind',
    'contentHash',
    'acceptance',
    'acceptedSequence',
    'originalApplied',
    'trustedDevice',
  });
  _header(m);
  final state = _string(m['state']),
      id = _id(m['operationId'], empty: true),
      kind = _string(m['kind']),
      hash = _hash(m['contentHash'], empty: true),
      acceptance = _string(m['acceptance']),
      seq = dagDecimal(m['acceptedSequence'], safe: true),
      applied = _bool(m['originalApplied']);
  if (state == 'none') {
    if (id.isNotEmpty ||
        kind.isNotEmpty ||
        hash.isNotEmpty ||
        seq != '0' ||
        acceptance != 'unknown' ||
        applied) {
      _invalid();
    }
  } else {
    if (id.isEmpty ||
        hash.isEmpty ||
        !{'transition-v2', 'recovered-v2'}.contains(kind) ||
        state != (seq == '0' ? 'pending' : 'accepted-original') ||
        acceptance != (seq == '0' ? 'unknown' : 'accepted') ||
        applied && seq == '0') {
      _invalid();
    }
  }
  return RecoveryPending(state, id, kind, hash, acceptance, seq, applied);
}

RecoveryEnrollment _enrollment(Object? raw) {
  final m = _object(raw, {
    'version',
    'profile',
    'state',
    'operationId',
    'phase',
    'contentHash',
    'acceptance',
    'acceptedSequence',
    'originalConfirmed',
    'needsOriginalOwner',
    'trustedDevice',
  });
  _header(m);
  final state = _string(m['state']),
      id = _id(m['operationId'], empty: true),
      phase = _string(m['phase']),
      hash = _hash(m['contentHash'], empty: true),
      acceptance = _string(m['acceptance']),
      seq = dagDecimal(m['acceptedSequence'], safe: true),
      confirmed = _bool(m['originalConfirmed']),
      needs = _bool(m['needsOriginalOwner']);
  if (state == 'none') {
    if (id.isNotEmpty ||
        phase.isNotEmpty ||
        hash.isNotEmpty ||
        acceptance != 'unknown' ||
        seq != '0' ||
        confirmed ||
        needs) {
      _invalid();
    }
  } else if (state == 'interrupted-original') {
    if (id.isEmpty ||
        !{'intent', 'challenged'}.contains(phase) ||
        hash.isNotEmpty ||
        acceptance != 'unknown' ||
        seq != '0' ||
        confirmed ||
        !needs) {
      _invalid();
    }
  } else {
    if (id.isEmpty ||
        hash.isEmpty ||
        phase.isNotEmpty ||
        needs ||
        state !=
            (seq == '0' ? 'pending-original' : 'accepted-not-device-applied') ||
        acceptance != (seq == '0' ? 'unknown' : 'accepted') ||
        confirmed && seq == '0') {
      _invalid();
    }
  }
  return RecoveryEnrollment(
    state,
    id,
    phase,
    hash,
    acceptance,
    seq,
    confirmed,
    needs,
  );
}

RecoveryChoices _choices(Object? raw) {
  final m = _object(raw, {
    'version',
    'profile',
    'sequence',
    'recoveryHeadHash',
    'environments',
    'trustedDevice',
  });
  _header(m);
  final rows = m['environments'];
  if (rows is! List || rows.isEmpty || rows.length > 256) _invalid();
  final ids = <String>{}, choices = <RecoveryEnvironmentChoice>[];
  for (final row in rows) {
    final r = _object(row, {'environmentId', 'keyVersion'}),
        id = _id(r['environmentId']);
    if (!ids.add(id)) _invalid();
    choices.add(
      RecoveryEnvironmentChoice(
        environmentId: id,
        keyVersion: dagDecimal(r['keyVersion'], positive: true),
      ),
    );
  }
  return RecoveryChoices(
    dagDecimal(m['sequence'], positive: true, safe: true),
    _hash(m['recoveryHeadHash']),
    choices,
  );
}

RecoveryTrusted _trusted(Object? raw) {
  final m = _object(raw, {
    'version',
    'profile',
    'operationId',
    'contentHash',
    'acceptedSequence',
    'trustedDevice',
    'binding',
    'view',
  });
  _header(m, trusted: true);
  final b = _object(m['binding'], {
    'accountId',
    'accountGeneration',
    'deviceId',
    'checkpoint',
  });
  final v = _object(m['view'], {
    'deviceId',
    'checkpoint',
    'experimental',
    'environments',
  });
  final checkpoint = dagDecimal(b['checkpoint'], positive: true, safe: true);
  final accepted = dagDecimal(
    m['acceptedSequence'],
    positive: true,
    safe: true,
  );
  if (_hash(b['deviceId']) != v['deviceId'] ||
      checkpoint != v['checkpoint'] ||
      BigInt.parse(checkpoint) < BigInt.parse(accepted)) {
    _invalid();
  }
  final view = decodeNativeView({...v, 'checkpoint': int.parse(checkpoint)});
  return RecoveryTrusted(
    operationId: _id(m['operationId']),
    contentHash: _hash(m['contentHash']),
    acceptedSequence: accepted,
    accountId: _id(b['accountId']),
    accountGeneration: dagDecimal(b['accountGeneration'], positive: true),
    deviceId: _hash(b['deviceId']),
    snapshot: view,
  );
}

/// 成熟 native 完成安全验证；Dart 只严格核验公开投影，不能自行验签或推断信任。
RecoveryReply decodeDAGRecovery(String operation, Map<String, Object?> raw) {
  if (!dagRecoveryFields.containsKey(operation) ||
      operation == 'cancelDAGRecoveryOwner') {
    _invalid();
  }
  final ok = _bool(raw['ok']);
  final trusted = _trustedOperations.contains(operation);
  nativeFields(raw, {
    'version',
    'profile',
    'operation',
    'trustedDevice',
    'ok',
    if (ok && operation == 'beginDAGRecoveryTransition')
      'recoveryCode'
    else
      'data',
    if (!ok) 'error',
  });
  if (raw['operation'] != operation) _invalid();
  _header(raw, trusted: ok && trusted);
  if (!ok) {
    final err = _object(raw['error'], {
      'code',
      'ownerRetained',
      'retryOriginal',
    });
    final code = _string(err['code']);
    final allowed = switch (operation) {
      'beginDAGRecoveryTransition' => {
        'ORIGINAL_RETRY_REQUIRED',
        'CODE_ALREADY_PREPARED',
      },
      'sealDAGRecoveryTransition' => {'NEW_CODE_REENTRY_REQUIRED'},
      'retryDAGRecoveryTransition' ||
      'sealDAGRecoveredDevice' ||
      'retryDAGRecoveredDevice' => {'ORIGINAL_RETRY_REQUIRED'},
      _ => <String>{},
    };
    if (!allowed.contains(code) ||
        err['ownerRetained'] != true ||
        err['retryOriginal'] != true) {
      _invalid();
    }
    return RecoveryReply(
      operation.contains('RecoveredDevice')
          ? _enrollment(raw['data'])
          : _owner(raw['data']),
      softError: code,
    );
  }
  final payload = switch (operation) {
    'openDAGRecoveryOwner' ||
    'dagRecoveryOwnerInfo' ||
    'retryDAGRecoveryTransition' => _owner(raw['data']),
    'dagRecoveryPreparationInfo' => _preparation(raw['data']),
    'dagRecoveryPendingInfo' ||
    'sealDAGRecoveryTransition' => _pending(raw['data']),
    'dagRecoveredDeviceInfo' ||
    'sealDAGRecoveredDevice' ||
    'retryDAGRecoveredDevice' => _enrollment(raw['data']),
    'dagRecoveredEnrollmentChoices' => _choices(raw['data']),
    'beginDAGRecoveryTransition' => _recoveryCode(raw['recoveryCode']),
    'queryDAGRecoveryOriginal' => _query(raw['data']),
    'applyDAGRecoveredDevice' ||
    'restoreDAGRecoveredDevice' ||
    'pullDAGRecoveredDevice' => _trusted(raw['data']),
    _ => _invalid(),
  };
  return RecoveryReply(payload);
}

RecoveryCode _recoveryCode(Object? raw) {
  final code = _string(raw);
  if (code.isEmpty || utf8.encode(code).length > 512) _invalid();
  return RecoveryCode(code);
}

RecoveryQuery _query(Object? raw) {
  final m = _object(raw, {
    'version',
    'profile',
    'pending',
    'observation',
    'confirmation',
    'rotationRequired',
    'trustedDevice',
  });
  _header(m);
  // 原生固定枚举；未知新状态不能当作可重试或可登记。
  final observation = _string(m['observation']),
      confirmation = _string(m['confirmation']);
  if (!{'unknown', 'not-accepted-at-query', 'accepted'}.contains(observation) ||
      !{
        'none',
        'receipt-observed',
        'original-verified-and-saved',
      }.contains(confirmation)) {
    _invalid();
  }
  return RecoveryQuery(
    _pending(m['pending']),
    observation,
    confirmation,
    _bool(m['rotationRequired']),
  );
}
