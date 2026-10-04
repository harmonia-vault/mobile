import 'dart:convert';
import 'dart:typed_data';

import '../account_reset/account_reset_gateway.dart';
import '../account_reset/account_reset_presentation.dart';

/// 与已审Kotlin内部delegate对应的窄port。
/// 平台实现只返回Go/原生drain成功后JSON；不得让Dart实现cleanup回调。
abstract interface class NativeAccountResetPort {
  Future<String> begin(String endpoint, Uint8List proof);
  Future<String> beginQueryOnly(String endpoint, Uint8List proof);
  Future<String> query();
  Future<String> prepare(Uint8List password, String confirmation);
  Future<String> complete();
  Future<void> invalidate();
}

/// 邮件申请是独立的接受请求，不产生证明/账号目录或设备信任。
abstract interface class NativeAccountResetMailPort {
  Future<String> requestEmail(String endpoint, Uint8List email);
}

class UnavailableAccountResetPort implements NativeAccountResetPort {
  const UnavailableAccountResetPort();
  Future<T> _closed<T>() async =>
      throw const AccountResetFailure(AccountResetFailureCode.unavailable);
  @override
  Future<String> begin(String endpoint, Uint8List proof) => _closed();
  @override
  Future<String> beginQueryOnly(String endpoint, Uint8List proof) => _closed();
  @override
  Future<String> query() => _closed();
  @override
  Future<String> prepare(Uint8List password, String confirmation) => _closed();
  @override
  Future<String> complete() => _closed();
  @override
  Future<void> invalidate() => _closed();
}

/// 编译声明与验收证据双门，默认均为空；不读ordinary profile、不假开cap。
class NativeAccountResetAdapter implements AccountResetGateway {
  factory NativeAccountResetAdapter({
    NativeAccountResetPort port = const UnavailableAccountResetPort(),
    Set<AccountResetAction> compiledActions = const {},
    Set<AccountResetAction> verifiedActions = const {},
  }) => NativeAccountResetAdapter._(
    port,
    Set.unmodifiable(
      compiledActions
          .intersection(verifiedActions)
          .difference(
            port is NativeAccountResetMailPort
                ? <AccountResetAction>{}
                : {AccountResetAction.requestEmail},
          ),
    ),
  );
  NativeAccountResetAdapter._(this._port, this.supportedActions);
  final NativeAccountResetPort _port;
  @override
  final Set<AccountResetAction> supportedActions;
  int _epoch = 0;
  bool _retired = false, _mailStarted = false, _mailRunning = false;
  bool _ownerStarted = false, _queryOnly = false, _verifiedPending = false;
  bool _prepareStarted = false,
      _prepareConfirmed = false,
      _queryRequired = false;
  void _require(AccountResetAction action) {
    if (_retired) {
      throw const AccountResetFailure(AccountResetFailureCode.retired);
    }
    if (!supportedActions.contains(action) ||
        !supportedActions.contains(AccountResetAction.cancel)) {
      throw const AccountResetFailure(AccountResetFailureCode.unavailable);
    }
  }

  Future<T> _fixed<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on AccountResetFailure {
      rethrow;
    } catch (_) {
      throw const AccountResetFailure(AccountResetFailureCode.nativeRejected);
    }
  }

  Future<T> _owned<T>(Future<T> Function() run) async {
    final epoch = _epoch;
    try {
      final result = await _fixed(run);
      if (epoch != _epoch || !_ownerStarted) {
        throw const AccountResetFailure(AccountResetFailureCode.retired);
      }
      return result;
    } catch (_) {
      if (epoch != _epoch || !_ownerStarted) {
        throw const AccountResetFailure(AccountResetFailureCode.retired);
      }
      rethrow;
    }
  }

  @override
  Future<void> requestEmailProof(String endpoint, String email) async {
    final bytes = Uint8List.fromList(utf8.encode(email));
    try {
      _require(AccountResetAction.requestEmail);
      AccountResetScope(endpoint);
      final port = _port;
      if (port is! NativeAccountResetMailPort) {
        throw const AccountResetFailure(AccountResetFailureCode.unavailable);
      }
      final mailPort = port as NativeAccountResetMailPort;
      if (_ownerStarted || _mailRunning) {
        throw const AccountResetFailure(AccountResetFailureCode.busy);
      }
      if (bytes.isEmpty ||
          bytes.length > 320 ||
          email.contains(RegExp(r'[\x00\r\n]'))) {
        throw const AccountResetFailure(AccountResetFailureCode.invalidInput);
      }
      final epoch = _epoch;
      _mailStarted = _mailRunning = true;
      String raw;
      try {
        raw = await _fixed(() => mailPort.requestEmail(endpoint, bytes));
      } catch (_) {
        if (epoch != _epoch || _retired) {
          throw const AccountResetFailure(AccountResetFailureCode.retired);
        }
        rethrow;
      }
      if (epoch != _epoch || _retired) {
        throw const AccountResetFailure(AccountResetFailureCode.retired);
      }
      final data = _object(raw);
      _fields(data, {'version', 'accepted', 'trustedDevice'});
      if (data['version'] is! int ||
          data['version'] != 1 ||
          data['accepted'] != true ||
          data['trustedDevice'] != false) {
        _bad();
      }
    } finally {
      _mailRunning = false;
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<AccountResetOutcome> _begin(
    String endpoint,
    Uint8List proof,
    bool cold,
  ) async {
    try {
      _require(
        cold
            ? AccountResetAction.beginQueryOnly
            : AccountResetAction.beginFresh,
      );
      AccountResetScope(endpoint);
      if (_ownerStarted ||
          _mailRunning ||
          proof.isEmpty ||
          proof.length > 4096) {
        throw const AccountResetFailure(AccountResetFailureCode.invalidInput);
      }
      _ownerStarted = true;
      _queryOnly = cold;
      final raw = await _owned(
        () => cold
            ? _port.beginQueryOnly(endpoint, proof)
            : _port.begin(endpoint, proof),
      );
      final out = decodeAccountResetOutcome(raw, statusOnly: true);
      _verifiedPending = !out.complete;
      return out;
    } finally {
      proof.fillRange(0, proof.length, 0);
    }
  }

  @override
  Future<AccountResetOutcome> beginFresh(String endpoint, Uint8List proof) =>
      _begin(endpoint, proof, false);
  @override
  Future<AccountResetOutcome> beginQueryOnly(
    String endpoint,
    Uint8List proof,
  ) => _begin(endpoint, proof, true);
  @override
  Future<AccountResetOutcome> query() async {
    _require(AccountResetAction.query);
    if (!_ownerStarted) {
      throw const AccountResetFailure(AccountResetFailureCode.queryRequired);
    }
    _verifiedPending = false;
    _queryRequired = true;
    final out = decodeAccountResetOutcome(
      await _owned(_port.query),
      statusOnly: true,
    );
    _verifiedPending = !out.complete;
    _queryRequired = false;
    return out;
  }

  @override
  Future<void> prepare(Uint8List password, String confirmation) async {
    try {
      _require(AccountResetAction.prepare);
      if (!_ownerStarted ||
          _queryOnly ||
          !_verifiedPending ||
          _prepareStarted ||
          password.isEmpty ||
          password.length > 16384 ||
          confirmation != accountResetConfirmation) {
        throw const AccountResetFailure(AccountResetFailureCode.invalidInput);
      }
      try {
        utf8.decode(password);
      } on FormatException {
        throw const AccountResetFailure(AccountResetFailureCode.invalidInput);
      }
      _prepareStarted = true;
      final data = _object(
        await _owned(() => _port.prepare(password, confirmation)),
      );
      _fields(data, {'version', 'prepared', 'trustedDevice'});
      if (data['version'] is! int ||
          data['version'] != 1 ||
          data['prepared'] != true ||
          data['trustedDevice'] != false) {
        _bad();
      }
      _prepareConfirmed = true;
    } finally {
      password.fillRange(0, password.length, 0);
    }
  }

  @override
  Future<AccountResetOutcome> complete() async {
    _require(AccountResetAction.complete);
    if (!_ownerStarted || _queryOnly || !_prepareConfirmed || _queryRequired) {
      throw const AccountResetFailure(AccountResetFailureCode.queryRequired);
    }
    _queryRequired = true;
    final out = decodeAccountResetOutcome(
      await _owned(_port.complete),
      statusOnly: false,
    );
    if (!out.complete) {
      _bad();
    }
    return out;
  }

  @override
  Future<void> invalidate() async {
    if (_retired) {
      return;
    }
    _retired = true;
    _epoch++;
    final started = _ownerStarted || _mailStarted;
    _ownerStarted = false;
    _verifiedPending = false;
    _prepareConfirmed = false;
    try {
      if (started) {
        await _fixed(_port.invalidate);
      }
    } finally {
      _ownerStarted = false;
      _verifiedPending = false;
      _prepareConfirmed = false;
    }
  }
}

Never _bad() =>
    throw const AccountResetFailure(AccountResetFailureCode.invalidResponse);
void _fields(Map<String, Object?> data, Set<String> expected) {
  if (data.length != expected.length ||
      data.keys.any((key) => !expected.contains(key))) {
    _bad();
  }
}

/// 固定小对象JSON：拒重复/转义同名key、数组、额外字段、错误类型和过大结果。
Map<String, Object?> _object(String raw) {
  if (utf8.encode(raw).length > 4096) {
    _bad();
  }
  final stack = <Set<String>>[];
  for (var i = 0; i < raw.length; i++) {
    final c = raw[i];
    if (c == '[' || c == ']') {
      _bad();
    }
    if (c == '{') {
      stack.add({});
      if (stack.length > 2) {
        _bad();
      }
    } else if (c == '}') {
      if (stack.isEmpty) {
        _bad();
      }
      stack.removeLast();
    } else if (c == '"') {
      final start = i++;
      while (i < raw.length && raw[i] != '"') {
        if (raw[i] == r'\') {
          i++;
        }
        i++;
      }
      if (i >= raw.length) {
        _bad();
      }
      var next = i + 1;
      while (next < raw.length && ' \r\n\t'.contains(raw[next])) {
        next++;
      }
      if (next < raw.length && raw[next] == ':') {
        Object? key;
        try {
          key = jsonDecode(raw.substring(start, i + 1));
        } catch (_) {
          _bad();
        }
        if (key is! String || stack.isEmpty || !stack.last.add(key)) {
          _bad();
        }
      }
    }
  }
  if (stack.isNotEmpty) {
    _bad();
  }
  Object? parsed;
  try {
    parsed = jsonDecode(raw);
  } catch (_) {
    _bad();
  }
  if (parsed is! Map<String, dynamic>) {
    _bad();
  }
  return Map<String, Object?>.from(parsed);
}

AccountResetOutcome decodeAccountResetOutcome(
  String raw, {
  required bool statusOnly,
}) {
  final data = _object(raw);
  _fields(data, {'version', 'trustedDevice', 'outcome'});
  if (data['version'] is! int ||
      data['version'] != 1 ||
      data['trustedDevice'] != false ||
      data['outcome'] is! Map<String, dynamic>) {
    _bad();
  }
  final out = Map<String, Object?>.from(data['outcome'] as Map);
  final source = out['source'];
  if (source == 'status') {
    _fields(out, {'state', 'accountId', 'accountGeneration', 'source'});
  } else if (source == 'commit' && !statusOnly) {
    _fields(out, {
      'state',
      'accountId',
      'accountGeneration',
      'source',
      'replayed',
    });
    if (out['replayed'] is! bool || out['state'] != 'complete') {
      _bad();
    }
  } else {
    _bad();
  }
  if (out['state'] != 'pending' && out['state'] != 'complete' ||
      out['accountId'] is! String ||
      !resetIdentifier(out['accountId'] as String) ||
      out['accountGeneration'] is! String ||
      !resetGeneration(
        out['accountGeneration'] as String,
        original: out['state'] == 'pending',
      ) ||
      out['state'] == 'complete' &&
          BigInt.parse(out['accountGeneration'] as String) < BigInt.two) {
    _bad();
  }
  return AccountResetOutcome(
    state: out['state'] as String,
    accountId: out['accountId'] as String,
    accountGeneration: out['accountGeneration'] as String,
    source: source as String,
    replayed: out['replayed'] as bool?,
  );
}
