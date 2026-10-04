import '../management/management_presentation.dart';
import '../vault_controller.dart';
import 'native_ui_contract.dart';

Never _bad() =>
    throw const GatewayFailure('原生管理结果不符合固定合同，未确认操作。', suspendVault: true);
String _id(Object? value) {
  if (value is! String || !nativeIdentifier(value)) _bad();
  return value;
}

String _generation(Object? value, {bool zero = false}) {
  if (zero && value == '0') return '0';
  return nativeGeneration(value);
}

int _number(Object? value, {bool positive = false}) {
  if (value is! int ||
      value < 0 ||
      value > 9007199254740991 ||
      positive && value == 0) {
    _bad();
  }
  return value;
}

DateTime? _expiry(Object? value) {
  final n = _number(value);
  if (n == 0) return null;
  // Dart DateTime范围比原生int64小；超出可表示范围不显示伪造日期。
  if (n > 8640000000000) _bad();
  return DateTime.fromMillisecondsSinceEpoch(n * 1000, isUtc: true);
}

List<ManagedDeviceAccess> decodeManagementDevices(
  Object? value,
  String environmentId,
  String currentDeviceId,
) {
  if (value is! List || value.length > 256) _bad();
  final result = <ManagedDeviceAccess>[], seen = <String>{};
  for (final item in value) {
    final row = nativeObject(item, '设备管理');
    nativeFields(row, {
      'deviceId',
      'role',
      'expiresAt',
      'keyVersion',
      'grantGeneration',
    });
    final id = _id(row['deviceId']);
    if (!seen.add(id)) _bad();
    final role = switch (row['role']) {
      'ro' => ManagedRole.readOnly,
      'rw' => ManagedRole.readWrite,
      'admin' => ManagedRole.admin,
      'none' => ManagedRole.none,
      'ungranted' => ManagedRole.ungranted,
      _ => null,
    };
    if (role == null) _bad();
    final generation = _generation(
      row['grantGeneration'],
      zero: role == ManagedRole.ungranted,
    );
    final expiry = _expiry(row['expiresAt']);
    final key = row['keyVersion'];
    if (role == ManagedRole.ungranted) {
      if (key != '' || expiry != null || generation != '0') _bad();
    } else {
      _generation(key);
    }
    result.add(
      ManagedDeviceAccess(
        deviceId: id,
        environmentId: environmentId,
        role: role,
        expiresAt: expiry,
        keyVersion: key as String,
        grantGeneration: generation,
        current: id == currentDeviceId,
      ),
    );
  }
  return List.unmodifiable(result);
}

ManagementOperation decodeManagementInfo(Object? value) {
  final m = nativeObject(value, '原管理操作');
  final state = m['state'];
  if (state == 'none') {
    nativeFields(m, {'state', 'attempted'});
    if (m['attempted'] != false) _bad();
    return const ManagementOperation(phase: ManagementPhase.idle);
  }
  if (!{'prepared', 'pending', 'accepted-not-applied'}.contains(state)) _bad();
  final kind = m['kind'];
  if (kind != 'grant' && kind != 'revoke') _bad();
  nativeFields(m, {
    'state',
    'id',
    'kind',
    'environmentId',
    'subjectDeviceId',
    'attempted',
    if (kind == 'revoke') 'expiresAt',
    if (state == 'accepted-not-applied') 'sequence',
  });
  final id = _id(m['id']);
  if (id.length > 64) _bad();
  if (m['attempted'] != (state != 'prepared')) _bad();
  final sequence = state == 'accepted-not-applied'
      ? _number(m['sequence'], positive: true)
      : 0;
  final expiry = kind == 'revoke' ? _expiry(m['expiresAt']) : null;
  if (kind == 'revoke' && expiry == null) _bad();
  return ManagementOperation(
    phase: switch (state) {
      'prepared' => ManagementPhase.prepared,
      'pending' => ManagementPhase.unknown,
      _ => ManagementPhase.acceptedNotApplied,
    },
    id: id,
    kind: kind as String,
    environmentId: _id(m['environmentId']),
    subjectDeviceId: _id(m['subjectDeviceId']),
    attempted: m['attempted'] as bool,
    sequence: sequence,
    acceptanceUnknown: state == 'pending',
    requestExpiresAt: expiry,
  );
}

class NativeManagementResult {
  const NativeManagementResult({
    required this.id,
    required this.accepted,
    required this.applied,
    required this.acceptanceUnknown,
    required this.canceled,
    required this.sequence,
  });
  final String id;
  final bool accepted, applied, acceptanceUnknown, canceled;
  final int sequence;
}

NativeManagementResult decodeManagementResult(
  Object? value,
  String originalId, {
  bool allowEmptyFailure = false,
}) {
  final m = nativeObject(value, '原管理结果');
  nativeFields(m, {
    'id',
    'accepted',
    'applied',
    'acceptanceUnknown',
    if (m.containsKey('sequence')) 'sequence',
    if (m.containsKey('canceled')) 'canceled',
  });
  final returnedId = m['id'];
  if (!(allowEmptyFailure && returnedId == '') &&
          _id(returnedId) != originalId ||
      m['accepted'] is! bool ||
      m['applied'] is! bool ||
      m['acceptanceUnknown'] is! bool) {
    _bad();
  }
  final accepted = m['accepted'] as bool,
      applied = m['applied'] as bool,
      unknown = m['acceptanceUnknown'] as bool;
  final canceled = m['canceled'] == true;
  if (m.containsKey('canceled') && !canceled) _bad();
  final sequence = m.containsKey('sequence')
      ? _number(m['sequence'], positive: true)
      : 0;
  if (returnedId == '' &&
      (accepted || applied || unknown || canceled || sequence != 0)) {
    _bad();
  }
  if (accepted != (sequence > 0) ||
      applied && !accepted ||
      accepted && unknown ||
      canceled && (accepted || applied || unknown || sequence != 0)) {
    _bad();
  }
  return NativeManagementResult(
    id: originalId,
    accepted: accepted,
    applied: applied,
    acceptanceUnknown: unknown,
    canceled: canceled,
    sequence: sequence,
  );
}

/// 只解码公开错误分类；失败data可保接受下界，不能将失败的applied字段升级成功。
class NativeManagementEnvelope {
  const NativeManagementEnvelope(this.data, {this.failure});
  final Object? data;
  final NativeIntentFailure? failure;
}

NativeManagementEnvelope decodeManagementEnvelope(
  Map<String, Object?> m,
  String operation, {
  String? originalId,
}) {
  if (m['version'] is! int ||
      m['version'] != 1 ||
      m['experimental'] != true ||
      m['ok'] is! bool) {
    _bad();
  }
  final ok = m['ok'] == true;
  nativeFields(m, {
    'version',
    'experimental',
    'ok',
    if (m.containsKey('data')) 'data',
    if (!ok) 'code',
    if (m.containsKey('retrySameId')) 'retrySameId',
  });
  if (ok) {
    if (m.containsKey('retrySameId') ||
        (operation != 'cancelManagement' && !m.containsKey('data')) ||
        (operation == 'cancelManagement' && m.containsKey('data'))) {
      _bad();
    }
    return NativeManagementEnvelope(m['data']);
  }
  final code = m['code'];
  if (code is! String ||
      !RegExp(r'^[A-Z_]{1,64}$').hasMatch(code) ||
      m.containsKey('retrySameId') && m['retrySameId'] != true ||
      m.containsKey('data') && operation != 'retryManagement') {
    _bad();
  }
  return NativeManagementEnvelope(
    m['data'],
    failure: NativeIntentFailure(
      code,
      retrySameId: originalId != null && m['retrySameId'] == true,
      id: originalId,
    ),
  );
}
