import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../recovery/recovery_presentation.dart';
import '../security/sensitive_input_guard.dart';
import 'design_system.dart';

/// 恢复面板：只展示业务投影并触发明确动作；不判断可信状态或能力。
class RecoveryPanel extends StatefulWidget {
  const RecoveryPanel({super.key, required this.controller});
  final RecoveryActions controller;

  @override
  State<RecoveryPanel> createState() => _RecoveryPanelState();
}

enum _Term {
  hour('1 小时', Duration(hours: 1)),
  day('24 小时', Duration(hours: 24)),
  week('7 天', Duration(days: 7)),
  revoked('直到撤销', null);

  const _Term(this.label, this.duration);
  final String label;
  final Duration? duration;
}

class _Pick {
  bool on = false;
  RecoveryRole? role;
  _Term? term;
}

const _maxSelections = 16;

const _stageText = <RecoveryStage, (String, String)>{
  RecoveryStage.entry: ('尚未开始', '可先检查恢复状态，或用账户和当前完整恢复码开启恢复。'),
  RecoveryStage.restricted: ('受限恢复', '已进入受限恢复，本设备不可信。下一步生成新的恢复码。'),
  RecoveryStage.codePrepared: ('新恢复码已生成', '离线抄写新恢复码，再完整重新输入一遍以准备恢复码轮换。'),
  RecoveryStage.transitionPending: ('转换等待中', '轮换已准备；准备不代表已提交。提交后仍需确认服务器结果。'),
  RecoveryStage.transitionConfirmed: ('转换已确认', '加载可授权环境，逐项明确选择角色与期限。'),
  RecoveryStage.enrollmentChoices: ('选择环境', '勾选需要恢复的环境（最多 16 项），并逐项选择角色与期限。'),
  RecoveryStage.enrollmentPending: ('登记等待中', '登记已准备；准备不代表已提交。提交后仍需确认服务器结果。'),
  RecoveryStage.enrollmentConfirmed: ('登记已确认', '登记已确认，但本设备仍未可信，需要完成设备验证。'),
  RecoveryStage.trusted: ('设备已验证', '设备验证已完成，可信会话由应用统一管理。'),
  RecoveryStage.closed: ('恢复已关闭', '恢复分支已关闭。在允许时可查询关闭结果或重新开始。'),
  RecoveryStage.interrupted: ('恢复已中断', '恢复过程中断，原操作仍保留，可用当前完整恢复码查询结果。'),
};

class _RecoveryPanelState extends State<RecoveryPanel> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _current = TextEditingController();
  final _reentry = TextEditingController();
  late final List<TextEditingController> _inputs = [
    _email,
    _password,
    _current,
    _reentry,
  ];
  late final SensitiveInputGuard _guard;
  late String _scope;
  final _picks = <String, _Pick>{};
  bool _pending = false;
  bool _clearingForm = false;
  bool _closeAck = false;
  String? _localError;

  RecoveryActions get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _scope = _c.sensitiveFormScope;
    for (final input in _inputs) {
      input.addListener(_refresh);
    }
    _guard = SensitiveInputGuard(_inputs, onCleared: _onGuardCleared);
  }

  @override
  void didUpdateWidget(RecoveryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final scope = _c.sensitiveFormScope;
    final changedController = !identical(
      oldWidget.controller,
      widget.controller,
    );
    if (changedController || scope != _scope) {
      _scope = scope;
      _clearLocalForm();
      _deferHideCode();
    }
  }

  @override
  void dispose() {
    _guard.dispose();
    for (final input in _inputs) {
      input.removeListener(_refresh);
      input.clear();
      input.dispose();
    }
    super.dispose();
  }

  void _refresh() {
    if (mounted && !_clearingForm) setState(() {});
  }

  void _onGuardCleared() {
    _closeAck = false;
    _picks.clear();
    _hideCode();
    _refresh();
  }

  void _hideCode() {
    if (_c.recovery.newCodeVisible) _c.setRecoveryCodeVisible(false);
  }

  // 当帧清理本地表单与授权选择；不在父组件构建中同步通知业务controller。
  void _clearLocalForm() {
    _clearingForm = true;
    try {
      for (final input in _inputs) {
        input.clear();
      }
      _picks.clear();
      _closeAck = false;
    } finally {
      _clearingForm = false;
    }
  }

  void _deferHideCode() {
    final controller = _c;
    final scope = _scope;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          identical(controller, _c) &&
          scope == _c.sensitiveFormScope) {
        _hideCode();
      }
    });
  }

  void _checkScope() {
    final scope = _c.sensitiveFormScope;
    if (scope == _scope) return;
    _scope = scope;
    _clearLocalForm();
    _deferHideCode();
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_pending) return;
    setState(() {
      _pending = true;
      _localError = null;
    });
    try {
      await task();
    } catch (_) {
      _localError = '操作未正常返回；请以上方状态为准，不要假定已提交或未提交。';
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  /// 读取一次码文本，先清空输入框，再转为一次性 bytes；结束后清零。
  Future<void> Function() _withCode(
    TextEditingController input,
    Future<void> Function(Uint8List code) use,
  ) {
    return () async {
      final bytes = Uint8List.fromList(utf8.encode(input.text));
      try {
        input.clear();
        await use(bytes);
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
    };
  }

  Future<void> _open() async {
    final email = _email.text.trim();
    final password = _password.text;
    _password.clear();
    await _withCode(
      _current,
      (code) =>
          _c.openRecovery(email: email, password: password, currentCode: code),
    )();
  }

  Future<void> _sealTransition() async {
    _hideCode();
    await _withCode(_reentry, _c.sealRecoveryTransition)();
  }

  Future<void> _closeOriginal() async {
    if (!_closeAck) return;
    setState(() => _closeAck = false);
    await _withCode(
      _current,
      (code) => _c.closeRecoveryOriginal(code, destructiveConfirmed: true),
    )();
  }

  String _key(RecoveryEnvironmentChoice ch) =>
      '${ch.environmentId}\u0000${ch.keyVersion}';

  List<(RecoveryEnvironmentChoice, _Pick)> _selected(RecoveryPresentation m) =>
      [
        for (final ch in m.choices)
          if (_picks[_key(ch)] case final p? when p.on) (ch, p),
      ];

  bool _selectionComplete(RecoveryPresentation m) {
    final s = _selected(m);
    return s.isNotEmpty &&
        s.length <= _maxSelections &&
        s.every((e) => e.$2.role != null && e.$2.term != null);
  }

  Future<void> _sealEnrollment() async {
    final m = _c.recovery;
    if (!_selectionComplete(m)) return;
    final now = DateTime.now();
    final list = <RecoverySelection>[];
    for (final (ch, p) in _selected(m)) {
      final d = p.term!.duration;
      list.add(
        RecoverySelection(
          environmentId: ch.environmentId,
          keyVersion: ch.keyVersion,
          role: p.role!,
          expiry: d == null
              ? const RecoveryExpiry.untilRevoked()
              : RecoveryExpiry.until(now.add(d)),
        ),
      );
    }
    await _c.sealRecoveryEnrollment(list);
  }

  Widget _gap(Widget child) =>
      Padding(padding: const EdgeInsets.only(top: 8), child: child);

  Widget _field(
    TextEditingController c,
    String label, {
    bool obscure = false,
    TextInputType type = TextInputType.visiblePassword,
    String? helper,
  }) {
    return _gap(
      TextField(
        controller: c,
        enabled: !_pending,
        obscureText: obscure,
        keyboardType: type,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        autofillHints: null,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 2,
        ),
      ),
    );
  }

  Widget _act(
    RecoveryPresentation m,
    RecoveryAction a,
    String label,
    Future<void> Function() task, {
    bool ready = true,
    String? need,
    bool danger = false,
    bool primary = false,
  }) {
    if (!m.allows(a)) return const SizedBox.shrink();
    final onPressed = ready && !_pending ? () => _run(task) : null;
    final cs = Theme.of(context).colorScheme;
    final button = primary
        ? FilledButton(onPressed: onPressed, child: Text(label))
        : OutlinedButton(
            style: danger
                ? OutlinedButton.styleFrom(
                    foregroundColor: cs.error,
                    side: BorderSide(color: cs.error),
                  )
                : null,
            onPressed: onPressed,
            child: Text(label),
          );
    final hint = !ready ? need : null;
    return _gap(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          button,
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(hint, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  HTone _stageTone(RecoveryPresentation m) => switch (m.stage) {
    RecoveryStage.trusted => m.trustedDevice ? HTone.success : HTone.accent,
    RecoveryStage.interrupted => HTone.warning,
    RecoveryStage.closed => HTone.neutral,
    _ => HTone.accent,
  };

  @override
  Widget build(BuildContext context) {
    _checkScope();
    final m = _c.recovery;
    const header = HHeader(title: '恢复访问', body: '使用恢复码，重新访问你的保险库。');
    if (m.stage == RecoveryStage.entry && m.actions.isEmpty && !m.busy) {
      return const HPage(
        narrow: true,
        children: [
          header,
          HNotice('当前无法在此设备恢复访问。你可以通过其他已授权设备重新授权。', icon: Icons.info_outline),
        ],
      );
    }
    final keys = m.choices.map(_key).toSet();
    _picks.removeWhere((k, _) => !keys.contains(k));

    bool rel(Set<RecoveryStage> s, List<RecoveryAction> a) =>
        s.contains(m.stage) || a.any(m.allows);
    final openRel =
        m.allows(RecoveryAction.open) ||
        (_pending && m.stage == RecoveryStage.entry);
    final queryRel =
        m.operationId != null || m.allows(RecoveryAction.queryOriginal);
    final closureRel = rel(
      {RecoveryStage.closed},
      [
        RecoveryAction.queryClosure,
        RecoveryAction.closeOriginal,
        RecoveryAction.restartAfterClosure,
      ],
    );
    final codeRel = openRel || queryRel || closureRel;
    final codeReady = _current.text.isNotEmpty;
    const needCode = '请先在“当前完整恢复码”中完整输入。';

    return HPage(
      narrow: true,
      children: [
        header,
        if (m.stage != RecoveryStage.entry || m.operationId != null)
          _statusSection(m)
        else if (!m.allows(RecoveryAction.open))
          HSection(
            form: true,
            children: [
              const Text('先检查是否有需要继续的恢复操作。'),
              _act(
                m,
                RecoveryAction.inspect,
                '检查恢复状态',
                _c.inspectRecovery,
                primary: true,
              ),
            ],
          ),
        if (openRel)
          HSection(
            form: true,
            children: [
              _field(_email, '邮箱', type: TextInputType.emailAddress),
              _field(_password, '密码', obscure: true),
              _field(_current, '恢复码'),
              _act(
                m,
                RecoveryAction.open,
                '恢复访问',
                _open,
                primary: true,
                ready:
                    _email.text.trim().isNotEmpty &&
                    _password.text.isNotEmpty &&
                    codeReady,
                need: '请输入邮箱、密码和恢复码。',
              ),
            ],
          ),
        if (codeRel && !openRel)
          HSection(
            title: '恢复码',
            form: true,
            children: [
              _field(_current, '当前完整恢复码'),
              if (queryRel)
                _act(
                  m,
                  RecoveryAction.queryOriginal,
                  '查询原操作结果',
                  _withCode(_current, _c.queryRecoveryOriginal),
                  ready: codeReady,
                  need: needCode,
                ),
            ],
          ),
        if (rel(
          {
            RecoveryStage.restricted,
            RecoveryStage.codePrepared,
            RecoveryStage.transitionPending,
          },
          [
            RecoveryAction.prepareCode,
            RecoveryAction.sealTransition,
            RecoveryAction.submitTransition,
          ],
        ))
          _newCodeSection(m),
        if (rel(
          {
            RecoveryStage.transitionConfirmed,
            RecoveryStage.enrollmentChoices,
            RecoveryStage.enrollmentPending,
          },
          [
            RecoveryAction.loadChoices,
            RecoveryAction.sealEnrollment,
            RecoveryAction.submitEnrollment,
          ],
        ))
          _enrollSection(m),
        if (rel(
          {RecoveryStage.enrollmentConfirmed, RecoveryStage.trusted},
          [
            RecoveryAction.verifyDevice,
            RecoveryAction.restoreDevice,
            RecoveryAction.pullDevice,
          ],
        ))
          HSection(
            title: '完成恢复',
            form: true,
            children: [
              if (!m.trustedDevice)
                HNotice('验证本设备后，即可访问已授权的环境。', icon: Icons.info_outline),
              _act(
                m,
                RecoveryAction.verifyDevice,
                '验证本设备',
                _c.verifyRecoveredDevice,
                primary: true,
              ),
              _act(
                m,
                RecoveryAction.restoreDevice,
                '恢复本机数据',
                _c.restoreRecoveredDevice,
              ),
              _act(
                m,
                RecoveryAction.pullDevice,
                '拉取最新数据',
                _c.pullRecoveredDevice,
              ),
            ],
          ),
        if ([
          RecoveryAction.cancelLocal,
          RecoveryAction.closeOriginal,
          RecoveryAction.queryClosure,
          RecoveryAction.restartAfterClosure,
        ].any(m.allows))
          _stopSection(m, codeReady, needCode),
      ],
    );
  }

  Widget _statusSection(RecoveryPresentation m) {
    final (title, body) = _stageText[m.stage]!;
    return HSection(
      form: true,
      children: [
        HNotice(body, title: title, tone: _stageTone(m)),
        if (m.busy) _gap(const LinearProgressIndicator()),
        if (m.error != null)
          _gap(HNotice(m.error!, title: '错误', tone: HTone.danger)),
        if (_localError != null)
          _gap(HNotice(_localError!, tone: HTone.warning)),
        if (m.needsOriginalOwner && !m.ownerAvailable)
          _gap(
            HNotice(
              '恢复已中断。请使用当前恢复码查询上次操作的结果。',
              title: '需要继续恢复',
              tone: HTone.warning,
            ),
          ),
        if (m.operationId != null) _operation(m),
        if (m.trustedDevice) _gap(HNotice('本设备已通过验证。', tone: HTone.success)),
        if (m.allows(RecoveryAction.inspect))
          _act(m, RecoveryAction.inspect, '刷新恢复状态', _c.inspectRecovery),
      ],
    );
  }

  Widget _operation(RecoveryPresentation m) {
    final confirmedStage = {
      RecoveryStage.transitionConfirmed,
      RecoveryStage.enrollmentChoices,
      RecoveryStage.enrollmentConfirmed,
      RecoveryStage.trusted,
    }.contains(m.stage);
    final unknown =
        !confirmedStage &&
        m.observation == 'unknown' &&
        m.confirmation != 'original-verified-and-saved';
    if (!unknown) return const SizedBox.shrink();
    return _gap(const HHint('上次操作的结果尚未确认，请先查询结果，不要重复提交。'));
  }

  Widget _newCodeSection(RecoveryPresentation m) {
    final theme = Theme.of(context);
    Widget? display;
    if (m.newCodeVisible) {
      final code = _c.recoveryCodeForDisplay;
      display = _gap(
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outline),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            code ?? '新恢复码当前不可显示。',
            style: code == null
                ? null
                : theme.textTheme.titleMedium?.copyWith(letterSpacing: 1.5),
          ),
        ),
      );
    }
    return HSection(
      title: '新恢复码',
      form: true,
      children: [
        HNotice(
          '新恢复码只生成一次。请离线抄写，不要截图或复制；之后需完整重新输入一遍。',
          tone: HTone.warning,
          icon: Icons.warning_amber_outlined,
        ),
        _act(m, RecoveryAction.prepareCode, '生成新恢复码', _c.prepareRecoveryCode),
        if (m.newCodeAvailable)
          _gap(
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _pending
                    ? null
                    : () => _c.setRecoveryCodeVisible(!m.newCodeVisible),
                icon: Icon(
                  m.newCodeVisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                label: Text(m.newCodeVisible ? '隐藏新恢复码' : '显示新恢复码'),
              ),
            ),
          ),
        ?display,
        _field(_reentry, '完整重新输入新恢复码', helper: '不会自动填充；请对照抄写内容完整输入。'),
        _act(
          m,
          RecoveryAction.sealTransition,
          '确认新恢复码',
          _sealTransition,
          ready: _reentry.text.isNotEmpty,
          need: '请完整重新输入新恢复码。',
        ),
        _act(
          m,
          RecoveryAction.submitTransition,
          '提交恢复码轮换',
          _c.submitRecoveryTransition,
          primary: true,
        ),
      ],
    );
  }

  Widget _enrollSection(RecoveryPresentation m) {
    final selected = _selected(m);
    final count = selected.length;
    return HSection(
      title: '授权环境',
      form: true,
      children: [
        _act(m, RecoveryAction.loadChoices, '加载可授权环境', _c.loadRecoveryChoices),
        if (m.choices.isEmpty)
          _gap(const Text('尚未加载环境列表。'))
        else ...[
          _gap(Text('已选 $count / $_maxSelections。每一项都需明确选择角色与期限。')),
          for (final ch in m.choices) _choiceRow(ch, count),
          if (count > 0)
            _gap(
              HNotice(
                [
                  for (final (ch, p) in selected)
                    '${ch.environmentId}（密钥版本 ${ch.keyVersion}）：'
                        '${p.role?.label ?? '未选角色'}，${p.term?.label ?? '未选期限'}',
                ].join('\n'),
                title: '本次选择摘要',
              ),
            ),
        ],
        _act(
          m,
          RecoveryAction.sealEnrollment,
          '确认授权选择',
          _sealEnrollment,
          ready: _selectionComplete(m),
          need: '请勾选 1–$_maxSelections 个环境，并为每项选择角色和期限。',
        ),
        _act(
          m,
          RecoveryAction.submitEnrollment,
          '提交登记',
          _c.submitRecoveryEnrollment,
          primary: true,
        ),
      ],
    );
  }

  Widget _choiceRow(RecoveryEnvironmentChoice ch, int count) {
    final p = _picks.putIfAbsent(_key(ch), _Pick.new);
    final canCheck = !_pending && (p.on || count < _maxSelections);
    final theme = Theme.of(context);
    return _gap(
      DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: p.on,
                onChanged: canCheck
                    ? (v) => setState(() {
                        p.on = v ?? false;
                        if (!p.on) {
                          p.role = null;
                          p.term = null;
                        }
                      })
                    : null,
                title: Text(ch.environmentId),
                subtitle: Text('密钥版本 ${ch.keyVersion}'),
              ),
              if (p.on) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text('角色', style: theme.textTheme.labelLarge),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final r in RecoveryRole.values)
                        ChoiceChip(
                          label: Text(r.label),
                          selected: p.role == r,
                          onSelected: _pending
                              ? null
                              : (s) => setState(() => p.role = s ? r : null),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 8),
                  child: Text(
                    '期限（从确认选择时起算）',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final t in _Term.values)
                        ChoiceChip(
                          label: Text(t.label),
                          selected: p.term == t,
                          onSelected: _pending
                              ? null
                              : (s) => setState(() => p.term = s ? t : null),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _stopSection(RecoveryPresentation m, bool codeReady, String needCode) {
    final closeAllowed = m.allows(RecoveryAction.closeOriginal);
    return HSection(
      title: '停止恢复',
      form: true,
      children: [
        if (m.allows(RecoveryAction.cancelLocal)) ...[
          const HHint('退出本次恢复，已提交的操作仍可继续查询。'),
          _act(
            m,
            RecoveryAction.cancelLocal,
            '暂时退出恢复',
            _c.cancelRecoveryLocally,
          ),
        ],
        if (closeAllowed) ...[
          const HNotice(
            '关闭后无法继续此恢复操作，且不能撤销。',
            title: '结束上次恢复',
            tone: HTone.danger,
          ),
          _gap(
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _closeAck,
              onChanged: closeAllowed && !_pending
                  ? (v) => setState(() => _closeAck = v ?? false)
                  : null,
              title: const Text('我确认结束此恢复操作'),
            ),
          ),
          _act(
            m,
            RecoveryAction.closeOriginal,
            '结束上次恢复',
            _closeOriginal,
            danger: true,
            ready: _closeAck && codeReady,
            need: '请确认并输入当前恢复码。',
          ),
        ],
        if (m.allows(RecoveryAction.queryClosure))
          _act(
            m,
            RecoveryAction.queryClosure,
            '查询关闭结果',
            _withCode(_current, _c.queryRecoveryClosure),
            ready: codeReady,
            need: needCode,
          ),
        if (m.allows(RecoveryAction.restartAfterClosure))
          _act(
            m,
            RecoveryAction.restartAfterClosure,
            '重新开始恢复',
            _withCode(_current, _c.restartRecoveryAfterClosure),
            ready: codeReady,
            need: needCode,
          ),
      ],
    );
  }
}
