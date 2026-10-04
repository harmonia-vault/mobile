import 'dart:typed_data';
import 'dart:convert';

import 'account_reset_gateway.dart';
import 'account_reset_presentation.dart';

/// 非视觉状态机：原proof/Attempt/秘密只在native RAM；Dart不持久重试材料。
class AccountResetCoordinator implements AccountResetActions {
  AccountResetCoordinator(
    this.gateway,
    this.scope, {
    required this.changed,
    required this.retireVisibleAccount,
  });
  final AccountResetGateway gateway;
  final AccountResetScope scope;
  final void Function() changed;

  /// 只撤回旧保险库展示/本机UI会话；不能授native清理或提交权限。
  final void Function() retireVisibleAccount;
  int _epoch = 0;
  bool _busy = false, _foreground = true, _retired = false, _disposed = false;
  bool _owner = false, _cold = false, _emailRequested = false;
  bool _prepareStarted = false,
      _attemptReady = false,
      _queried = false,
      _cleanupConfirmed = false;
  AccountResetOutcome? _outcome;
  String? _originalGeneration, _error;
  AccountResetStage _stage = AccountResetStage.entry;
  bool _cap(AccountResetAction a) => gateway.supportedActions.contains(a);
  bool get _alive => !_retired && !_disposed && _foreground;
  @override
  String get accountResetFormScope => 'account-reset:$_epoch:${_stage.name}';
  @override
  bool get retainAccountResetInput => _alive && !_busy;
  @override
  AccountResetPresentation get accountReset {
    final actions = <AccountResetAction>{};
    void permit(AccountResetAction action, bool condition) {
      if (_alive &&
          !_busy &&
          condition &&
          _cap(action) &&
          _cap(AccountResetAction.cancel)) {
        actions.add(action);
      }
    }

    permit(AccountResetAction.requestEmail, !_owner && !_emailRequested);
    permit(AccountResetAction.beginFresh, !_owner && _emailRequested);
    permit(AccountResetAction.beginQueryOnly, !_owner && !_emailRequested);
    permit(AccountResetAction.query, _owner && !_cleanupConfirmed);
    permit(
      AccountResetAction.prepare,
      _owner &&
          !_cold &&
          _queried &&
          _outcome?.state == 'pending' &&
          !_prepareStarted,
    );
    permit(
      AccountResetAction.complete,
      _owner && !_cold && _attemptReady && _queried && !_cleanupConfirmed,
    );
    if (_alive &&
        _cap(AccountResetAction.cancel) &&
        (_busy || _owner || _emailRequested)) {
      actions.add(AccountResetAction.cancel);
    }
    return AccountResetPresentation(
      stage: !_retired && gateway.supportedActions.isEmpty
          ? AccountResetStage.unavailable
          : _stage,
      status: _status,
      busy: _busy,
      accountId: _outcome?.accountId ?? '',
      accountGeneration: _outcome?.accountGeneration ?? '',
      source: _outcome?.source ?? '',
      queryOnly: _cold,
      localCleanupConfirmed: _cleanupConfirmed,
      error: _error,
      actions: actions,
    );
  }

  String get _status => switch (_stage) {
    AccountResetStage.unavailable => '账号重置原生接口尚未验收。',
    AccountResetStage.entry =>
      gateway.supportedActions.isEmpty
          ? '账号重置原生接口尚未验收。'
          : '新流程须先申请邮件证明；冷续办只能查询。',
    AccountResetStage.awaitingProof => '请使用本次新申请邮件中的完整证明。',
    AccountResetStage.proofPending =>
      _cold ? '原证明尚未完成；冷查询不能创建或重试提交。' : '邮件证明有效；重置会删除旧保险库，不能恢复旧数据。',
    AccountResetStage.prepared => '已冻结本次原请求；后续不能替换密码或证明。',
    AccountResetStage.unknown => '结果未确认；只能查询原RAM请求，不能重开或替换密码。',
    AccountResetStage.serverComplete => '服务器已确认重置；本机清理尚未由完成入口确认。',
    AccountResetStage.complete => '重置与本机清理已确认；没有登录、恢复旧保险库或授设备信任。',
    AccountResetStage.interrupted => '原RAM范围已退役或状态不明；冷续办只能查询原邮件证明。',
  };
  void _require(AccountResetAction action) {
    if (!accountReset.allows(action)) {
      throw const AccountResetFailure(AccountResetFailureCode.unavailable);
    }
  }

  Future<void> _run(
    AccountResetAction action,
    Future<void> Function() run,
  ) async {
    _require(action);
    final epoch = _epoch;
    _busy = true;
    _error = null;
    changed();
    try {
      _postCheck(epoch);
      await run();
      if (!_alive || epoch != _epoch) {
        throw const AccountResetFailure(AccountResetFailureCode.retired);
      }
    } on AccountResetFailure catch (e) {
      _postCheck(epoch);
      if (_alive && epoch == _epoch) {
        _error = e.message;
        _queried = false;
        _stage = _owner
            ? AccountResetStage.unknown
            : AccountResetStage.interrupted;
      }
      rethrow;
    } catch (_) {
      if (_alive && epoch == _epoch) {
        _error = const AccountResetFailure(
          AccountResetFailureCode.nativeRejected,
        ).message;
        _queried = false;
        _stage = AccountResetStage.unknown;
      }
      throw const AccountResetFailure(AccountResetFailureCode.nativeRejected);
    } finally {
      if (epoch == _epoch && !_disposed) {
        _busy = false;
        changed();
      }
    }
  }

  void _postCheck(int epoch) {
    if (!_alive || epoch != _epoch) {
      throw const AccountResetFailure(AccountResetFailureCode.retired);
    }
  }

  void _accept(AccountResetOutcome out, int epoch) {
    _postCheck(epoch);
    final original = out.complete
        ? (BigInt.parse(out.accountGeneration) - BigInt.one).toString()
        : out.accountGeneration;
    if (_outcome != null && _outcome!.accountId != out.accountId ||
        _originalGeneration != null && _originalGeneration != original ||
        scope.accountId.isNotEmpty &&
            (scope.accountId != out.accountId ||
                scope.accountGeneration != original) ||
        _outcome?.complete == true && !out.complete) {
      throw const AccountResetFailure(AccountResetFailureCode.invalidResponse);
    }
    _originalGeneration = original;
    _outcome = out;
    _queried = true;
    _stage = out.complete
        ? AccountResetStage.serverComplete
        : AccountResetStage.proofPending;
  }

  @override
  Future<void> requestAccountResetEmail(String email) =>
      _run(AccountResetAction.requestEmail, () async {
        if (email.isEmpty ||
            utf8.encode(email).length > 320 ||
            RegExp(r'[\x00\r\n]').hasMatch(email)) {
          throw const AccountResetFailure(AccountResetFailureCode.invalidInput);
        }
        final epoch = _epoch;
        await gateway.requestEmailProof(scope.endpoint, email);
        _postCheck(epoch);
        _emailRequested = true;
        _stage = AccountResetStage.awaitingProof;
      });
  Future<void> _begin(Uint8List proof, bool cold) async {
    try {
      await _run(
        cold
            ? AccountResetAction.beginQueryOnly
            : AccountResetAction.beginFresh,
        () async {
          if (proof.isEmpty || proof.length > 4096) {
            throw const AccountResetFailure(
              AccountResetFailureCode.invalidInput,
            );
          }
          final epoch = _epoch;
          _owner = true;
          _cold = cold;
          final out = await (cold
              ? gateway.beginQueryOnly(scope.endpoint, proof)
              : gateway.beginFresh(scope.endpoint, proof));
          _accept(out, epoch);
        },
      );
    } finally {
      proof.fillRange(0, proof.length, 0);
    }
  }

  @override
  Future<void> beginFreshAccountReset(Uint8List emailProof) =>
      _begin(emailProof, false);
  @override
  Future<void> queryColdAccountReset(Uint8List originalEmailProof) =>
      _begin(originalEmailProof, true);
  @override
  Future<void> queryOriginalAccountReset() =>
      _run(AccountResetAction.query, () async {
        final epoch = _epoch;
        _accept(await gateway.query(), epoch);
      });
  @override
  Future<void> prepareAccountReset(
    Uint8List newPassword, {
    required String destructiveConfirmation,
  }) async {
    try {
      // 本地确认/输入失败不能改变原准备记录，也不发native调用。
      if (newPassword.isEmpty ||
          newPassword.length > 16384 ||
          destructiveConfirmation != accountResetConfirmation) {
        throw const AccountResetFailure(AccountResetFailureCode.invalidInput);
      }
      await _run(AccountResetAction.prepare, () async {
        final epoch = _epoch;
        _prepareStarted = true;
        await gateway.prepare(newPassword, destructiveConfirmation);
        _postCheck(epoch);
        _attemptReady = true;
        _stage = AccountResetStage.prepared;
      });
    } finally {
      newPassword.fillRange(0, newPassword.length, 0);
    }
  }

  @override
  Future<void> completeAccountReset() =>
      _run(AccountResetAction.complete, () async {
        final epoch = _epoch;
        _queried = false;
        retireVisibleAccount();
        _postCheck(epoch);
        final out = await gateway.complete();
        _accept(out, epoch);
        if (!out.complete) {
          throw const AccountResetFailure(
            AccountResetFailureCode.invalidResponse,
          );
        }
        _cleanupConfirmed = true;
        _stage = AccountResetStage.complete;
      });
  Future<void> _retire() async {
    if (_retired) {
      return;
    }
    _epoch++;
    _retired = true;
    _owner = false;
    _queried = false;
    _attemptReady = false;
    _busy = false;
    _emailRequested = false;
    _cleanupConfirmed = false;
    _stage = AccountResetStage.interrupted;
    if (!_disposed) {
      changed();
    }
    try {
      await gateway.invalidate();
    } catch (_) {
      _error = const AccountResetFailure(
        AccountResetFailureCode.localCleanupUnconfirmed,
      ).message;
      if (!_disposed) {
        changed();
      }
      throw const AccountResetFailure(
        AccountResetFailureCode.localCleanupUnconfirmed,
      );
    }
  }

  @override
  Future<void> cancelAccountResetLocally() => _retire();
  Future<void> onBackground() {
    _foreground = false;
    return _retire();
  }

  Future<void> invalidateScope() => _retire();
  Future<void> dispose() {
    _disposed = true;
    return _retire();
  }
}
