import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../vault_controller.dart';
import 'recovery_gateway.dart';
import 'recovery_presentation.dart';

class _RecoveryInputFailure extends GatewayFailure {
  const _RecoveryInputFailure(super.message);
}

/// 非视觉业务状态。原包、签名、owner 与密码学始终由 native 持有。
class RecoveryCoordinator {
  RecoveryCoordinator(
    this.gateway, {
    required this.changed,
    required this.onTrusted,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final RecoveryGateway? gateway;
  final void Function() changed;
  final void Function(RecoveryTrusted, String nativeOperation) onTrusted;
  final DateTime Function() now;
  int _epoch = 0;
  bool _inspected = false, _owner = false, _visible = false, _trusted = false;
  bool _unknown = false, _disposed = false, _canceling = false;
  String? _code, _error;
  String _status = '请先检查本机保存的原恢复操作。',
      _observation = 'unknown',
      _confirmation = 'none';
  RecoveryStage _stage = RecoveryStage.entry;
  RecoveryOwner? _ownerInfo;
  RecoveryPreparation? _preparation;
  RecoveryPending? _pending;
  RecoveryEnrollment? _enrollment;
  RecoveryChoices? _choices;
  RecoveryResolution? _resolution;
  Map<String, String>? _sealedSelection;
  DateTime? _ownerDeadline;
  Timer? _timer;
  bool get active =>
      _trusted ||
      _owner ||
      _hasOriginal ||
      _resolution != null ||
      _unknown ||
      _code != null;
  String? get visibleCode => _visible ? _code : null;
  bool get _liveOwner =>
      _owner && _ownerDeadline != null && now().isBefore(_ownerDeadline!);
  bool _cap(String op) => gateway?.recoveryCapabilities.contains(op) == true;
  bool get _hasOriginal =>
      _preparation != null || _pending != null || _enrollment != null;
  String? get _id =>
      _enrollment?.operationId ??
      _pending?.operationId ??
      _preparation?.operationId ??
      _resolution?.operationId;
  String? get _hash => _enrollment?.contentHash ?? _pending?.contentHash;

  RecoveryPresentation presentation({
    required bool available,
    required bool busy,
  }) {
    final actions = <RecoveryAction>{};
    void permit(RecoveryAction action, String op, bool condition) {
      if (available && !busy && !_canceling && condition && _cap(op)) {
        actions.add(action);
      }
    }

    permit(
      RecoveryAction.inspect,
      gateway?.recoveryStateMayExist == false
          ? 'openDAGRecoveryOwner'
          : 'dagRecoveredDeviceInfo',
      !_trusted &&
          (gateway?.recoveryStateMayExist == false ||
              _cap('dagRecoveryPreparationInfo') &&
                  _cap('dagRecoveryPendingInfo')),
    );
    permit(
      RecoveryAction.open,
      'openDAGRecoveryOwner',
      (_inspected || gateway?.recoveryStateMayExist == false) &&
          !_hasOriginal &&
          _resolution == null &&
          !_liveOwner &&
          !_trusted &&
          !_unknown,
    );
    permit(
      RecoveryAction.prepareCode,
      'beginDAGRecoveryTransition',
      _liveOwner &&
          _ownerInfo?.rotationRequired == true &&
          _pending == null &&
          _enrollment == null &&
          _code == null &&
          !_unknown,
    );
    permit(
      RecoveryAction.sealTransition,
      'sealDAGRecoveryTransition',
      _liveOwner && _pending == null && _enrollment == null && _code != null,
    );
    permit(
      RecoveryAction.submitTransition,
      'retryDAGRecoveryTransition',
      _cap('dagRecoveryPendingInfo') &&
          _liveOwner &&
          _pending?.kind == 'transition-v2' &&
          _pending?.originalApplied != true,
    );
    permit(
      RecoveryAction.queryOriginal,
      'queryDAGRecoveryOriginal',
      !_liveOwner &&
          (_pending != null || _enrollment?.contentHash.isNotEmpty == true),
    );
    permit(
      RecoveryAction.loadChoices,
      'dagRecoveredEnrollmentChoices',
      _liveOwner &&
          _ownerInfo?.rotationRequired == false &&
          _pending?.kind == 'transition-v2' &&
          _pending?.originalApplied == true &&
          _enrollment == null,
    );
    permit(
      RecoveryAction.sealEnrollment,
      'sealDAGRecoveredDevice',
      _liveOwner &&
          _choices != null &&
          (_enrollment == null || _enrollment!.state == 'interrupted-original'),
    );
    permit(
      RecoveryAction.submitEnrollment,
      'retryDAGRecoveredDevice',
      _liveOwner &&
          _enrollment?.contentHash.isNotEmpty == true &&
          _enrollment?.originalConfirmed != true,
    );
    permit(
      RecoveryAction.verifyDevice,
      'applyDAGRecoveredDevice',
      _enrollment?.originalConfirmed == true &&
          _enrollment?.acceptedSequence != '0' &&
          !_trusted,
    );
    permit(
      RecoveryAction.restoreDevice,
      'restoreDAGRecoveredDevice',
      _inspected && !_liveOwner && !_trusted,
    );
    permit(RecoveryAction.pullDevice, 'pullDAGRecoveredDevice', _trusted);
    final closureTarget =
        _cap('dagRecoveryResolutionDiscovery') &&
        !_trusted &&
        !_liveOwner &&
        _enrollment == null &&
        _preparation == null &&
        (_pending?.kind == 'transition-v2' || _resolution != null);
    permit(
      RecoveryAction.queryClosure,
      'queryDAGRecoveryResolution',
      closureTarget &&
          _resolution?.accepted != true &&
          _cap('dagRecoveryResolutionInfo'),
    );
    permit(
      RecoveryAction.closeOriginal,
      'closeDAGRecoveryOriginal',
      closureTarget &&
          _resolution?.closed != true &&
          _resolution?.accepted != true &&
          _pending?.originalApplied != true &&
          _cap('dagRecoveryResolutionInfo'),
    );
    permit(
      RecoveryAction.restartAfterClosure,
      'openDAGRecoveryAfterClosure',
      closureTarget &&
          _resolution?.closed == true &&
          !_hasOriginal &&
          !_unknown,
    );

    // 本机取消允许在网络在途时执行。它不依赖业务 busy 锁。
    if (available &&
        _cap('cancelDAGRecoveryOwner') &&
        (_liveOwner || busy || _hasOriginal || _unknown)) {
      actions.add(RecoveryAction.cancelLocal);
    }
    return RecoveryPresentation(
      stage: _stage,
      status: _status,
      busy: busy || _canceling,
      operationId: _id,
      acceptedSequence: _resolution != null && _resolution!.sequence != '0'
          ? _resolution!.sequence
          : _enrollment?.acceptedSequence ?? _pending?.acceptedSequence,
      preparationPhase: _enrollment?.phase ?? _preparation?.phase,
      observation: _observation,
      confirmation: _confirmation,
      needsOriginalOwner:
          _preparation?.needsOriginalOwner == true ||
          _enrollment?.needsOriginalOwner == true,
      ownerAvailable: _liveOwner,
      newCodeAvailable: _code != null,
      newCodeVisible: _visible,
      trustedDevice: _trusted,
      error: _error,
      choices: _choices?.environments ?? const [],
      actions: actions,
      blockedReasons: const {
        RecoveryAction.queryClosure: '仅支持已准备完成的恢复码更换；须先结束本机恢复过程，并确认此设备支持查询。',
        RecoveryAction.closeOriginal: '仅支持尚未确认完成的恢复码更换；关闭服务器操作须单独确认，本机取消不能代替。',
        RecoveryAction.restartAfterClosure: '须先确认服务器操作已关闭并已保存到本机，才能重新开始。',
      },
    );
  }

  void _forgetCode() {
    _code = null;
    _visible = false;
  }

  void hideCode(bool visible) {
    _visible = visible && _code != null;
    changed();
  }

  void _retireOwner() {
    _owner = false;
    _ownerInfo = null;
    _ownerDeadline = null;
    _timer?.cancel();
    _timer = null;
    _forgetCode();
  }

  void invalidate({bool reset = false}) {
    _epoch++;
    _canceling = false;
    gateway?.retireRecoveryResults();
    _retireOwner();
    _choices = null;
    _trusted = false;
    if (reset) {
      _inspected = false;
      _unknown = false;
      _preparation = null;
      _pending = null;
      _enrollment = null;
      _sealedSelection = null;
      _resolution = null;
      _error = null;
      _stage = RecoveryStage.entry;
      _status = '请先检查本机保存的原恢复操作。';
      _observation = 'unknown';
      _confirmation = 'none';
    } else {
      _unknown = true;
      _stage = RecoveryStage.interrupted;
      _status = '本机恢复过程已关闭；持久原操作保留，需检查或查询原结果。';
    }
  }

  Future<void> cancel() async {
    if (_canceling) return;
    invalidate();
    final epoch = _epoch;
    _canceling = true;
    changed();
    try {
      await gateway?.cancelRecoveryOwner();
    } on GatewayFailure catch (e) {
      if (_alive(epoch)) _error = e.message;
    } catch (_) {
      if (_alive(epoch)) _error = '本机原生取消未确认；原操作仍保留。';
    } finally {
      if (_alive(epoch)) _canceling = false;
      changed();
    }
  }

  void dispose() {
    _disposed = true;
    invalidate(reset: true);
  }

  Future<void> run(Future<void> Function(int epoch) body) async {
    final epoch = _epoch;
    final wasTrusted = _trusted;
    _error = null;
    try {
      await body(epoch);
    } on _RecoveryInputFailure catch (e) {
      if (_alive(epoch)) _error = e.message;
      rethrow;
    } on GatewayFailure catch (e) {
      if (_alive(epoch)) {
        _retireOwner();
        _trusted = false;
        _choices = null;
        _unknown = true;
        _stage = RecoveryStage.interrupted;
        _error = e.message;
        _status = '结果未确认；保留原操作，不能据此重建或重投新意图。';
      }
      throw GatewayFailure(
        e.message,
        suspendVault: wasTrusted || e.suspendVault,
        invalidateSession: e.invalidateSession,
      );
    } catch (_) {
      if (_alive(epoch)) {
        _retireOwner();
        _trusted = false;
        _choices = null;
        _unknown = true;
        _stage = RecoveryStage.interrupted;
        _error = '恢复结果未确认；请检查原操作。';
      }
      throw GatewayFailure('恢复结果未确认；请检查原操作。', suspendVault: wasTrusted);
    } finally {
      changed();
    }
  }

  bool _alive(int epoch) => !_disposed && epoch == _epoch;
  Future<RecoveryReply?> _call(
    int epoch,
    String operation, {
    Map<String, String> fields = const {},
    Uint8List? code,
  }) async {
    final bytes = code ?? Uint8List(0);
    try {
      if (!_alive(epoch) || gateway == null || !_cap(operation)) {
        throw const GatewayFailure('当前无法执行此恢复操作，请先完成前一步。');
      }
      final reply = await gateway!.executeRecovery(operation, fields, bytes);
      if (!_alive(epoch)) return null;
      return reply;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  void _keepOwner(RecoveryOwner info) {
    if (!_owner) {
      final server = DateTime.fromMillisecondsSinceEpoch(
        int.parse(info.expiresAt) * 1000,
        isUtc: true,
      );
      final local = now().add(const Duration(minutes: 5));
      _ownerDeadline = server.isBefore(local) ? server : local;
      _timer?.cancel();
      _timer = Timer(
        _ownerDeadline!.difference(now()).isNegative
            ? Duration.zero
            : _ownerDeadline!.difference(now()),
        () {
          unawaited(cancel());
        },
      );
    }
    _owner = true;
    _ownerInfo = info;
  }

  void _applyPending(RecoveryPending value) {
    if (value.state == 'none') return;
    final previous = _pending;
    if (previous != null &&
        previous.kind == value.kind &&
        (previous.operationId != value.operationId ||
            previous.contentHash != value.contentHash ||
            BigInt.parse(previous.acceptedSequence) >
                BigInt.parse(value.acceptedSequence) ||
            previous.originalApplied && !value.originalApplied)) {
      throw const GatewayFailure('原恢复包身份或已确认下界改变，已拒绝。');
    }
    if (_preparation != null &&
        value.kind == 'transition-v2' &&
        _preparation!.operationId != value.operationId) {
      throw const GatewayFailure('原准备意图已改变，已拒绝。');
    }
    _pending = value;
    _preparation = null;
    _stage = value.kind == 'recovered-v2'
        ? (value.originalApplied
              ? RecoveryStage.enrollmentConfirmed
              : RecoveryStage.enrollmentPending)
        : (value.originalApplied
              ? RecoveryStage.transitionConfirmed
              : RecoveryStage.transitionPending);
    _status = value.originalApplied
        ? '原操作已验证并保存；设备仍未完成正式本机验证。'
        : '原操作已密封；明确提交或沿原 ID 查询，未知不等于未接受。';
  }

  void _applyEnrollment(RecoveryEnrollment value) {
    if (value.state == 'none') return;
    final previous = _enrollment;
    if (previous != null &&
        (previous.operationId != value.operationId ||
            previous.contentHash.isNotEmpty &&
                previous.contentHash != value.contentHash ||
            BigInt.parse(previous.acceptedSequence) >
                BigInt.parse(value.acceptedSequence) ||
            previous.originalConfirmed && !value.originalConfirmed)) {
      throw const GatewayFailure('原登记包或已确认下界改变，已拒绝。');
    }
    _enrollment = value;
    _stage = value.originalConfirmed
        ? RecoveryStage.enrollmentConfirmed
        : RecoveryStage.enrollmentPending;
    _status = value.originalConfirmed
        ? '原登记已确认；须正式 Boot/Pull 和本机保存成功才能进入保险库。'
        : '本机登记只续办原 ID 与原包；尚未可信。';
  }

  void _soft(RecoveryReply reply) {
    _error = switch (reply.softError) {
      'NEW_CODE_REENTRY_REQUIRED' => '完整新码不匹配；仍是同一原意图，请重新输入。',
      'CODE_ALREADY_PREPARED' => '原新码已生成；不会生成另一新码。',
      _ => '本次原操作结果未知；活恢复过程保留，只能续办原操作。',
    };
    final payload = reply.payload;
    if (payload is RecoveryOwner) _keepOwner(payload);
    if (payload is RecoveryEnrollment) _applyEnrollment(payload);
  }

  Future<void> inspect() => run((epoch) async {
    if (gateway?.recoveryStateMayExist == false && _resolution != null) {
      throw const GatewayFailure('已保存恢复结果对应的本机设备未返回，已停止。');
    }
    if (gateway?.recoveryStateMayExist == false &&
        !_hasOriginal &&
        !_liveOwner) {
      _inspected = true;
      _unknown = false;
      _stage = RecoveryStage.entry;
      _status = '原生未发现本机设备钥匙；输入账号和旧码后将明确创建本机受保护设备。';
      return;
    }
    RecoveryResolutionDiscovery? discovery;
    if (!_liveOwner && _cap('dagRecoveryResolutionDiscovery')) {
      final result = await _call(epoch, 'dagRecoveryResolutionDiscovery');
      if (result == null) return;
      discovery = result.payload as RecoveryResolutionDiscovery;
      if (discovery.state == 'none' && _resolution != null) {
        throw const GatewayFailure('已保存的恢复操作结果未返回，已停止。');
      }
      if (discovery.state == 'closed') {
        final info = await _resolutionInfo(epoch, discovery);
        if (info == null) return;
        _applyResolution(info, fromInfo: true);
        _inspected = true;
        return;
      }
    }
    final enrolled = await _call(epoch, 'dagRecoveredDeviceInfo');
    if (enrolled == null) return;
    final e = enrolled.payload as RecoveryEnrollment;
    if (e.state != 'none') {
      if (discovery?.state == 'supported-original') {
        throw const GatewayFailure('本机恢复目标在检查期间改变，已停止。');
      }
      _applyEnrollment(e);
      _inspected = true;
      return;
    }
    final prepared = await _call(epoch, 'dagRecoveryPreparationInfo');
    if (prepared == null) return;
    final p = prepared.payload as RecoveryPreparation;
    if (p.state != 'none') {
      if (discovery?.state == 'supported-original') {
        throw const GatewayFailure('本机恢复目标在检查期间改变，已停止。');
      }
      if (_id != null && _id != p.operationId) {
        throw const GatewayFailure('本机原操作身份改变，已拒绝。');
      }
      _preparation = p;
      _stage = _liveOwner
          ? RecoveryStage.codePrepared
          : RecoveryStage.interrupted;
      _status = '原恢复准备已保存；重输或续办必须使用原活恢复过程。';
      _inspected = true;
      return;
    }
    final pending = await _call(epoch, 'dagRecoveryPendingInfo');
    if (pending == null) return;
    final original = pending.payload as RecoveryPending;
    if (original.state == 'none' && _hasOriginal) {
      throw const GatewayFailure('原恢复记录未返回；不能视为可新建。');
    }
    if (original.state == 'none' &&
        discovery != null &&
        discovery.state != 'none') {
      throw const GatewayFailure('本机恢复状态不能作为新的恢复入口，已停止。');
    }
    _applyPending(original);
    if (discovery?.state == 'supported-original') {
      final info = await _resolutionInfo(epoch, discovery!);
      if (info == null) return;
      _applyResolution(info, fromInfo: true);
    }
    _inspected = true;
    if (!_hasOriginal && !_liveOwner) {
      _unknown = false;
      _stage = RecoveryStage.entry;
      _status = '本机未返回未决恢复原包；可输入账号和完整旧码。';
    }
  });
  Future<void> open(String email, String password, Uint8List code) =>
      run((epoch) async {
        final reply = await _call(
          epoch,
          'openDAGRecoveryOwner',
          fields: {'email': email, 'password': password},
          code: code,
        );
        if (reply == null) return;
        _keepOwner(reply.payload as RecoveryOwner);
        _stage = RecoveryStage.restricted;
        _unknown = false;
        _status = '已打开受限恢复过程；账号登录和恢复码验证都不表示本机可信。';
      });
  Future<void> prepare() => run((epoch) async {
    final reply = await _call(epoch, 'beginDAGRecoveryTransition');
    if (reply == null) return;
    if (!reply.ok) {
      _soft(reply);
      return;
    }
    _code = (reply.payload as RecoveryCode).value;
    _visible = false;
    _stage = RecoveryStage.codePrepared;
    _status = '新码只留在本次内存；保存并完整重新输入后才可密封。';
  });
  Future<void> seal(Uint8List code) => run((epoch) async {
    final reply = await _call(epoch, 'sealDAGRecoveryTransition', code: code);
    if (reply == null) return;
    if (!reply.ok) {
      _soft(reply);
      return;
    }
    _applyPending(reply.payload as RecoveryPending);
    _forgetCode();
  });
  Future<void> submitTransition() => run((epoch) async {
    final reply = await _call(epoch, 'retryDAGRecoveryTransition');
    if (reply == null) return;
    if (!reply.ok) {
      _soft(reply);
      return;
    }
    _keepOwner(reply.payload as RecoveryOwner);
    // 成功 owner DTO 本身不证明原包已保存；另读精确元数据。
    final pending = await _call(epoch, 'dagRecoveryPendingInfo');
    if (pending != null) _applyPending(pending.payload as RecoveryPending);
  });
  Future<void> query(Uint8List code) => run((epoch) async {
    final reply = await _call(epoch, 'queryDAGRecoveryOriginal', code: code);
    if (reply == null) return;
    final query = reply.payload as RecoveryQuery;
    _applyPending(query.pending);
    _observation = query.observation;
    _confirmation = query.confirmation;
    // 新查询会话已关闭，不能复活原 RAM owner。
    _retireOwner();
    if (query.pending.kind == 'recovered-v2') {
      final r = await _call(epoch, 'dagRecoveredDeviceInfo');
      if (r != null) _applyEnrollment(r.payload as RecoveryEnrollment);
    }
  });
  Future<RecoveryResolution?> _resolutionInfo(
    int epoch,
    RecoveryResolutionDiscovery discovery,
  ) async {
    if (!discovery.supported) {
      throw const GatewayFailure('当前恢复阶段不支持服务器操作关闭；原结果尚未重新确认。');
    }
    final reply = await _call(epoch, 'dagRecoveryResolutionInfo');
    if (reply == null) return null;
    final info = reply.payload as RecoveryResolution;
    if (info.operationId != discovery.operationId ||
        info.targetHash != discovery.targetHash ||
        info.closed != (discovery.state == 'closed')) {
      throw const GatewayFailure('本机恢复目标在检查期间改变，已停止。');
    }
    return info;
  }

  void _applyResolution(RecoveryResolution value, {bool fromInfo = false}) {
    final previous = _resolution;
    if (_enrollment != null ||
        _preparation != null ||
        _pending != null &&
            (_pending!.kind != 'transition-v2' ||
                _pending!.operationId != value.operationId) ||
        previous != null &&
            (previous.operationId != value.operationId ||
                previous.targetHash != value.targetHash ||
                !(fromInfo &&
                        previous.accepted &&
                        value.localState == 'pending') &&
                    (BigInt.parse(previous.sequence) >
                            BigInt.parse(value.sequence) ||
                        previous.localState != 'pending' &&
                            (previous.localState != value.localState ||
                                previous.sequence != value.sequence))) ||
        _pending != null &&
            _pending!.acceptedSequence != '0' &&
            (value.closed ||
                value.accepted &&
                    value.sequence != _pending!.acceptedSequence)) {
      throw const GatewayFailure('原恢复操作的身份或已确认结果改变，已拒绝。');
    }
    if (fromInfo &&
        previous?.accepted == true &&
        value.localState == 'pending') {
      _applyResolution(previous!);
      return;
    }
    _resolution = value;
    // 只读 Info 的 unknown 不能覆盖已经核验的原包接受状态。
    if (fromInfo &&
        value.localState == 'pending' &&
        _pending?.originalApplied == true) {
      return;
    }
    _observation = value.observation;
    _confirmation = value.confirmation;
    _retireOwner();
    _choices = null;
    _trusted = false;
    _unknown = false;
    if (value.closed) {
      _pending = null;
      _sealedSelection = null;
      _stage = RecoveryStage.closed;
      _status = '服务器已关闭这次恢复操作，结果已保存到本机；可明确开始新的恢复。';
    } else if (value.accepted) {
      _stage = RecoveryStage.transitionConfirmed;
      _status = '原恢复操作已完成并核验；它不能再关闭，本机设备仍未可信。';
    } else {
      _stage = RecoveryStage.transitionPending;
      _status = '原恢复操作尚未确认终态；请沿同一操作继续查询或明确关闭。';
    }
  }

  Future<void> resolve(
    Uint8List code, {
    bool closeRequested = false,
    bool destructiveConfirmed = false,
  }) async {
    try {
      await run((epoch) async {
        if (closeRequested && !destructiveConfirmed) {
          throw const _RecoveryInputFailure('请明确确认关闭这次服务器恢复操作。');
        }
        if (_liveOwner ||
            _enrollment != null ||
            _preparation != null ||
            (_pending?.kind != 'transition-v2' && _resolution == null) ||
            _resolution?.accepted == true ||
            closeRequested &&
                (_resolution?.closed == true ||
                    _pending?.originalApplied == true)) {
          throw const _RecoveryInputFailure('当前阶段不支持关闭或查询服务器恢复操作。');
        }
        // targetHash 是原生原目标摘要，不是 pending 的 contentHash。
        final discovered = await _call(epoch, 'dagRecoveryResolutionDiscovery');
        if (discovered == null) return;
        final info = await _resolutionInfo(
          epoch,
          discovered.payload as RecoveryResolutionDiscovery,
        );
        if (info == null) return;
        _applyResolution(info, fromInfo: true);
        if (info.closed && closeRequested) return;
        final reply = await _call(
          epoch,
          closeRequested
              ? 'closeDAGRecoveryOriginal'
              : 'queryDAGRecoveryResolution',
          fields: {
            'operationId': info.operationId,
            'targetHash': info.targetHash,
          },
          code: code,
        );
        if (reply != null) {
          _applyResolution(reply.payload as RecoveryResolution);
        }
      });
    } finally {
      code.fillRange(0, code.length, 0);
    }
  }

  Future<void> restartAfterClosure(Uint8List code) async {
    try {
      await run((epoch) async {
        if (_resolution?.closed != true ||
            _hasOriginal ||
            _liveOwner ||
            _unknown) {
          throw const _RecoveryInputFailure('尚未确认保存关闭结果，不能重新开始恢复。');
        }
        final reply = await _call(
          epoch,
          'openDAGRecoveryAfterClosure',
          code: code,
        );
        if (reply == null) return;
        final owner = reply.payload as RecoveryOwner;
        if (!owner.rotationRequired) {
          throw const GatewayFailure('新的受限恢复状态无效，未继续。');
        }
        _resolution = null;
        _observation = 'unknown';
        _confirmation = 'none';
        _keepOwner(owner);
        _stage = RecoveryStage.restricted;
        _unknown = false;
        _status = '新的受限恢复过程已打开；请明确生成新的恢复码。';
      });
    } finally {
      code.fillRange(0, code.length, 0);
    }
  }

  Future<void> loadChoices() => run((epoch) async {
    final reply = await _call(epoch, 'dagRecoveredEnrollmentChoices');
    if (reply == null) return;
    _choices = reply.payload as RecoveryChoices;
    _stage = RecoveryStage.enrollmentChoices;
    _status = '明确选择环境版本、角色和期限；没有默认选择或默认授权。';
  });
  Future<void> sealEnrollment(List<RecoverySelection> selections) => run((
    epoch,
  ) async {
    final choices = _choices;
    if (choices == null || selections.isEmpty || selections.length > 16) {
      throw const _RecoveryInputFailure('须明确选择 1–16 个候选环境及各自角色、期限。');
    }
    final seen = <String>{},
        versions = {
          for (final e in choices.environments) e.environmentId: e.keyVersion,
        };
    final rows = <Map<String, String>>[];
    for (final s in selections) {
      final expiry = s.expiry.at;
      if (!seen.add(s.environmentId) ||
          versions[s.environmentId] != s.keyVersion ||
          expiry != null && !expiry.isAfter(now())) {
        throw const _RecoveryInputFailure('环境版本、重复选择或期限无效；未发送登记。');
      }
      rows.add({
        'environmentId': s.environmentId,
        'keyVersion': s.keyVersion,
        'role': s.role.wireValue,
        'expiresAt': expiry == null
            ? '0'
            : (expiry.millisecondsSinceEpoch ~/ 1000).toString(),
      });
    }
    final fields = <String, String>{
      'expectedSequence': choices.sequence,
      'recoveryHeadHash': choices.headHash,
      'selections': jsonEncode(rows),
    };
    if (_sealedSelection != null &&
        jsonEncode(_sealedSelection) != jsonEncode(fields)) {
      throw const _RecoveryInputFailure('已经保存原登记选择，不能更换选择重试。');
    }
    _sealedSelection ??= Map.unmodifiable(fields);
    final reply = await _call(
      epoch,
      'sealDAGRecoveredDevice',
      fields: _sealedSelection!,
    );
    if (reply == null) return;
    if (!reply.ok) {
      _soft(reply);
      return;
    }
    _applyEnrollment(reply.payload as RecoveryEnrollment);
  });
  Future<void> submitEnrollment() => run((epoch) async {
    final reply = await _call(
      epoch,
      'retryDAGRecoveredDevice',
      fields: {'operationId': _id!, 'contentHash': _hash!},
    );
    if (reply == null) return;
    if (!reply.ok) {
      _soft(reply);
      return;
    }
    _applyEnrollment(reply.payload as RecoveryEnrollment);
  });
  Future<void> device(String operation) => run((epoch) async {
    final reply = await _call(
      epoch,
      operation,
      fields: operation == 'applyDAGRecoveredDevice'
          ? {'operationId': _id!, 'contentHash': _hash!}
          : const {},
    );
    if (reply == null) return;
    final trusted = reply.payload as RecoveryTrusted;
    if (_enrollment != null &&
        (_enrollment!.operationId != trusted.operationId ||
            _enrollment!.contentHash != trusted.contentHash ||
            _enrollment!.acceptedSequence != trusted.acceptedSequence)) {
      throw const GatewayFailure('正式本机验证没有对应当前原登记，已拒绝。');
    }
    _retireOwner();
    _choices = null;
    _trusted = true;
    _stage = RecoveryStage.trusted;
    _status = operation == 'restoreDAGRecoveredDevice'
        ? '已保存来源通过本机复验；当前为离线缓存读取，尚未确认网络状态。'
        : '恢复完成，数据已同步到本机。';
    onTrusted(trusted, operation);
  });
}
