import "../email_code.dart";

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account_reset/account_reset_presentation.dart';
import '../security/sensitive_input_guard.dart';
import 'design_system.dart';

const _confirmWord = 'DELETE_OLD_VAULT';

/// 账号安全 / 受阻账号入口；打开与否由父界面决定。
class AccountResetEntry extends StatelessWidget {
  const AccountResetEntry({super.key, required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => HRow(
    title: '通过邮箱重置账号',
    subtitle: '无法恢复旧数据时使用；会删除旧保险库数据',
    icon: Icons.lock_reset,
    tone: HTone.warning,
    onTap: onOpen,
  );
}

class AccountResetPanel extends StatefulWidget {
  const AccountResetPanel({
    super.key,
    required this.controller,
    this.onFinished,
  });
  final AccountResetActions controller;
  final Future<void> Function()? onFinished;

  @override
  State<AccountResetPanel> createState() => _AccountResetPanelState();
}

class _AccountResetPanelState extends State<AccountResetPanel> {
  final _email = TextEditingController();
  final _freshProof = TextEditingController();
  final _coldProof = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  late final SensitiveInputGuard _guard;
  late String _scope;
  Listenable? _listening;
  bool _pending = false, _cancelling = false;
  int _inputEpoch = 0;
  String? _localError;
  Timer? _emailTimer;
  int _lastEmailWait = 0;
  int get _emailWait {
    final deadline = widget.controller.accountReset.emailRetryAt;
    final milliseconds =
        deadline?.difference(DateTime.now()).inMilliseconds ?? 0;
    return milliseconds <= 0 ? 0 : (milliseconds / 1000).ceil();
  }

  List<TextEditingController> get _inputs => [
    _email,
    _freshProof,
    _coldProof,
    _password,
    _confirm,
  ];

  @override
  void initState() {
    super.initState();
    _scope = widget.controller.accountResetFormScope;
    _guard = SensitiveInputGuard(
      _inputs,
      onCleared: () {
        if (mounted) setState(_clearForm);
      },
    );
    _attach();
    _emailTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final wait = _emailWait;
      if (mounted && wait != _lastEmailWait) {
        setState(() => _lastEmailWait = wait);
      }
    });
  }

  void _attach() {
    final c = widget.controller;
    if (c is Listenable) {
      _listening = c as Listenable;
      _listening!.addListener(_onChanged);
    }
  }

  void _detach() {
    _listening?.removeListener(_onChanged);
    _listening = null;
  }

  void _onChanged() {
    _syncScope();
    if (!widget.controller.retainAccountResetInput) {
      // 只清控件自身的输入；不修改已交给原操作的局部字节或pending寿命。
      for (final input in _inputs) {
        input.clear();
      }
    }
    if (mounted) setState(() {});
  }

  void _syncScope() {
    final s = widget.controller.accountResetFormScope;
    if (s == _scope) return;
    _scope = s;
    _clearForm();
  }

  void _clearForm() {
    _inputEpoch++;
    _pending = false;
    _cancelling = false;
    for (final i in _inputs) {
      i.clear();
    }
    _localError = null;
  }

  bool _isCurrent(int epoch, AccountResetActions owner) =>
      mounted &&
      epoch == _inputEpoch &&
      identical(owner, widget.controller) &&
      _scope == widget.controller.accountResetFormScope;

  @override
  void didUpdateWidget(AccountResetPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      _detach();
      _scope = widget.controller.accountResetFormScope;
      _clearForm();
      _attach();
    }
    _syncScope();
  }

  @override
  void dispose() {
    _emailTimer?.cancel();
    _detach();
    _guard.dispose();
    for (final i in _inputs) {
      i.clear();
      i.dispose();
    }
    super.dispose();
  }

  bool _can(AccountResetPresentation p, AccountResetAction a) =>
      p.allows(a) && !p.busy && !_pending;

  Future<void> _run(Future<void> Function() action) async {
    if (_pending) return;
    final epoch = _inputEpoch;
    final owner = widget.controller;
    setState(() {
      _pending = true;
      _localError = null;
    });
    try {
      await action();
    } catch (_) {
      if (_isCurrent(epoch, owner)) {
        setState(() => _localError = '操作未完成，请查看上方状态后再试。');
      }
    } finally {
      if (_isCurrent(epoch, owner)) setState(() => _pending = false);
    }
  }

  /// 一次转为字节→先清输入→await→finally 清零自身字节。
  Future<void> _sendBytes(
    TextEditingController input,
    int max,
    String invalid,
    Future<void> Function(Uint8List bytes) send, {
    TextEditingController? alsoClear,
  }) async {
    if (_pending) return;
    final epoch = _inputEpoch;
    final owner = widget.controller;
    final bytes = utf8.encode(input.text);
    try {
      if (bytes.isEmpty || bytes.length > max) {
        setState(() => _localError = invalid);
        return;
      }
      input.clear();
      alsoClear?.clear();
      setState(() {
        _pending = true;
        _localError = null;
      });
      await send(bytes);
    } catch (_) {
      if (_isCurrent(epoch, owner)) {
        setState(() => _localError = '操作未完成，请查看上方状态后再试。');
      }
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      if (_isCurrent(epoch, owner)) setState(() => _pending = false);
    }
  }

  /// 本地取消不受其它动作的局部 pending 限制；不代表服务器关闭或本机清理。
  Future<void> _cancel() async {
    if (_cancelling ||
        !widget.controller.accountReset.allows(AccountResetAction.cancel)) {
      return;
    }
    final epoch = _inputEpoch;
    final owner = widget.controller;
    setState(() => _cancelling = true);
    _freshProof.clear();
    _coldProof.clear();
    _password.clear();
    _confirm.clear();
    try {
      await owner.cancelAccountResetLocally();
    } catch (_) {
      if (_isCurrent(epoch, owner)) {
        setState(() => _localError = '本机取消未完成，请稍后再试。');
      }
    } finally {
      if (_isCurrent(epoch, owner)) setState(() => _cancelling = false);
    }
  }

  Widget _field(
    TextEditingController c,
    String label, {
    bool obscure = true,
    TextInputType type = TextInputType.visiblePassword,
  }) => TextField(
    controller: c,
    obscureText: obscure,
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    smartDashesType: SmartDashesType.disabled,
    smartQuotesType: SmartQuotesType.disabled,
    keyboardType: type,
    decoration: InputDecoration(labelText: label),
    onChanged: (_) => setState(() {}),
  );

  Widget _codeField(TextEditingController controller) => TextField(
    controller: controller,
    keyboardType: TextInputType.text,
    textCapitalization: TextCapitalization.characters,
    maxLength: 8,
    autofillHints: const [AutofillHints.oneTimeCode],
    inputFormatters: [
      FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
    ],
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    decoration: const InputDecoration(
      labelText: '八位验证码',
      helperText: '可直接粘贴，连字符和空格会自动去除。',
    ),
    onChanged: (_) => setState(() {}),
  );

  (String, HTone)? _stageNotice(
    AccountResetPresentation p,
  ) => switch (p.stage) {
    AccountResetStage.unavailable => ('此设备尚不能进行邮箱重置。', HTone.neutral),
    AccountResetStage.entry => null,
    AccountResetStage.awaitingProof => ('请查收重置邮件，输入八位字母数字验证码。', HTone.accent),
    AccountResetStage.proofPending => (
      p.queryOnly ? '邮件凭证有效；当前只查询原重置。' : '邮件凭证已确认，可以设置新密码并明确确认删除。',
      HTone.warning,
    ),
    AccountResetStage.prepared => ('已准备，尚未提交。', HTone.warning),
    AccountResetStage.unknown => ('提交结果未知。请查询或续办原重置，不要重新设置密码。', HTone.warning),
    AccountResetStage.serverComplete => (
      '服务器已完成重置，本机旧数据清理尚未确认。',
      HTone.warning,
    ),
    AccountResetStage.complete =>
      p.localCleanupConfirmed
          ? ('重置已完成，本机旧数据已清理。', HTone.success)
          : ('服务器已完成重置，本机旧数据清理尚未确认。', HTone.warning),
    AccountResetStage.interrupted => (
      '已在本机取消。这不代表服务器已关闭此重置，也不代表本机数据已清理。',
      HTone.neutral,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final p = c.accountReset;
    final notice = _stageNotice(p);
    final finished =
        p.stage == AccountResetStage.serverComplete ||
        p.stage == AccountResetStage.complete;
    final canPrepare =
        _can(p, AccountResetAction.prepare) &&
        !p.queryOnly &&
        _password.text.isNotEmpty &&
        _confirm.text == _confirmWord;
    final showProgress =
        p.allows(AccountResetAction.query) ||
        p.allows(AccountResetAction.complete) ||
        p.allows(AccountResetAction.cancel);
    return HPage(
      narrow: true,
      children: [
        const HHeader(
          title: '重置账号',
          body: '通过邮箱重新设置账号。旧保险库数据将被删除，无法恢复。',
          tone: HTone.warning,
        ),
        HSection(
          form: true,
          children: [
            if (p.busy || _pending || _cancelling)
              const LinearProgressIndicator(),
            HNotice(
              notice?.$1 ?? p.status,
              tone: notice?.$2 ?? HTone.neutral,
              icon: Icons.info_outline,
            ),
            if (finished) const HHint('请使用新密码重新登录，并初始化新的保险库。'),
            if (p.localCleanupConfirmed && widget.onFinished != null)
              FilledButton(
                onPressed: _pending ? null : () => _run(widget.onFinished!),
                child: const Text('返回登录'),
              ),
            if (p.queryOnly) const HHint('当前为查询模式，只能查询原重置，不能设置新密码。'),
            if (p.error != null) HNotice(p.error!, tone: HTone.danger),
            if (_localError != null) HNotice(_localError!, tone: HTone.danger),
          ],
        ),
        if (p.allows(AccountResetAction.requestEmail))
          HSection(
            title: '申请重置邮件',
            form: true,
            children: [
              _field(
                _email,
                '账号邮箱',
                obscure: false,
                type: TextInputType.emailAddress,
              ),
              FilledButton(
                onPressed:
                    _can(p, AccountResetAction.requestEmail) &&
                        _emailWait == 0 &&
                        _email.text.trim().contains('@')
                    ? () => _run(
                        () => c.requestAccountResetEmail(_email.text.trim()),
                      )
                    : null,
                child: Text(_emailWait > 0 ? '请 $_emailWait 秒后重试' : '发送重置邮件'),
              ),
            ],
          ),
        if (p.allows(AccountResetAction.beginFresh))
          HSection(
            title: '开始新的重置',
            form: true,
            footer: '验证码不区分大小写，15 分钟内有效，最多尝试 5 次。重新发送后旧码失效。',
            children: [
              _codeField(_freshProof),
              FilledButton(
                onPressed:
                    _can(p, AccountResetAction.beginFresh) &&
                        normalizeEmailCode(_freshProof.text) != null
                    ? () => _sendBytes(
                        _freshProof,
                        8,
                        '请输入八位字母数字验证码。',
                        c.beginFreshAccountReset,
                      )
                    : null,
                child: const Text('开始新的重置'),
              ),
            ],
          ),
        if (p.allows(AccountResetAction.beginQueryOnly))
          HSection(
            title: '查询已提交的重置',
            form: true,
            footer: '只用于查询之前的重置进度，不能开始新的重置或设置新密码。',
            children: [
              _field(
                _email,
                '原账号邮箱',
                obscure: false,
                type: TextInputType.emailAddress,
              ),
              _codeField(_coldProof),
              OutlinedButton(
                onPressed:
                    _can(p, AccountResetAction.beginQueryOnly) &&
                        _email.text.trim().contains('@') &&
                        normalizeEmailCode(_coldProof.text) != null
                    ? () => _sendBytes(
                        _coldProof,
                        8,
                        '请输入原邮件中的八位字母数字验证码。',
                        (code) => c.queryColdAccountReset(
                          utf8.encode(
                            jsonEncode({
                              'email': _email.text.trim(),
                              'code': normalizeEmailCode(utf8.decode(code)),
                            }),
                          ),
                        ),
                      )
                    : null,
                child: const Text('查询原重置'),
              ),
            ],
          ),
        if (p.allows(AccountResetAction.prepare) && !p.queryOnly)
          HSection(
            title: '设置新密码并确认删除',
            form: true,
            children: [
              const HNotice(
                '继续会永久删除旧保险库数据，无法恢复。',
                tone: HTone.danger,
                icon: Icons.warning_amber_outlined,
              ),
              _field(_password, '新密码'),
              _field(
                _confirm,
                '请完整输入 $_confirmWord 以确认',
                obscure: false,
                type: TextInputType.text,
              ),
              FilledButton(
                onPressed: canPrepare
                    ? () {
                        final confirmation = _confirm.text;
                        _sendBytes(
                          _password,
                          16384,
                          '新密码长度不正确。',
                          (bytes) => c.prepareAccountReset(
                            bytes,
                            destructiveConfirmation: confirmation,
                          ),
                          alsoClear: _confirm,
                        );
                      }
                    : null,
                child: const Text('准备重置'),
              ),
              const HHint('准备后不会立即执行，需要另行提交重置。'),
            ],
          ),
        if (showProgress)
          HSection(
            title: '原重置',
            children: [
              Wrap(
                spacing: HSpace.sm,
                runSpacing: HSpace.sm,
                children: [
                  if (p.allows(AccountResetAction.complete))
                    FilledButton(
                      onPressed: _can(p, AccountResetAction.complete)
                          ? () => _run(c.completeAccountReset)
                          : null,
                      child: Text(
                        p.stage == AccountResetStage.prepared
                            ? '提交重置'
                            : '续办原重置',
                      ),
                    ),
                  if (p.allows(AccountResetAction.query))
                    OutlinedButton(
                      onPressed: _can(p, AccountResetAction.query)
                          ? () => _run(c.queryOriginalAccountReset)
                          : null,
                      child: const Text('查询原重置'),
                    ),
                  if (p.allows(AccountResetAction.cancel))
                    TextButton(
                      onPressed: _cancelling ? null : _cancel,
                      child: const Text('取消本机操作'),
                    ),
                ],
              ),
              if (p.allows(AccountResetAction.cancel))
                const HHint('取消只停止本机操作，不会关闭服务器上的重置，也不会清理本机数据。'),
            ],
          ),
        if (p.accountId.isNotEmpty || p.accountGeneration.isNotEmpty)
          HSection(
            children: [
              HDetails(
                title: '技术信息',
                children: [
                  HKeyValue('账号ID', p.accountId, mono: true, selectable: true),
                  HKeyValue('账号代际', p.accountGeneration, mono: true),
                  if (p.source.isNotEmpty) HKeyValue('来源', p.source),
                ],
              ),
            ],
          ),
      ],
    );
  }
}
