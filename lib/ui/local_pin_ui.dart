import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../native/native_pin_adapter.dart';
import '../vault_controller.dart';
import 'design_system.dart';

final _pinPattern = RegExp(r'^[0-9]{6,32}$');

/// 每次请求都是全新的对话框；取消、返回或离开 App 时返回 null。
Future<LocalPINInput?> showLocalPINPrompt(
  BuildContext context,
  LocalPINPromptRequest request,
) => showDialog<LocalPINInput>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _PINDialog(request: request),
);

/// 只有明确点击“清除本机访问”才返回 true。
Future<bool> showLocalPINForgetPrompt(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ForgetDialog(),
    ) ??
    false;

/// 只关闭当前对话框；重复点击或对话框已不在最上层时不再 pop。
bool _popSelf(BuildContext context, Object? result) {
  final route = ModalRoute.of(context);
  if (route == null || !route.isCurrent) return false;
  Navigator.of(context).pop(result);
  return true;
}

String _operationTitle(String op) => switch (op) {
  'restoreSession' || 'unlock' => '打开本机已授权的保险库',
  'revealSecret' || 'copySecret' => '查看敏感内容',
  'approveDevice' => '批准新设备',
  _ => '确认本次操作',
};

class _DialogFrame extends StatelessWidget {
  const _DialogFrame({
    required this.icon,
    required this.title,
    required this.children,
    required this.actions,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Dialog(
      child: SafeArea(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: HSize.formWidth),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(HSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(icon, size: HSize.icon),
                    const SizedBox(width: HSpace.sm),
                    Expanded(child: Text(title, style: t.titleLarge)),
                  ],
                ),
                for (final w in children) ...[
                  const SizedBox(height: HSpace.md),
                  w,
                ],
                const SizedBox(height: HSpace.xl),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: HSpace.sm,
                  runSpacing: HSpace.sm,
                  children: actions,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PINDialog extends StatefulWidget {
  const _PINDialog({required this.request});

  final LocalPINPromptRequest request;

  @override
  State<_PINDialog> createState() => _PINDialogState();
}

class _PINDialogState extends State<_PINDialog> {
  final _pin = TextEditingController();
  final _again = TextEditingController();
  late final AppLifecycleListener _life;
  Timer? _timer;
  int _wait = 0;
  bool _show = false;
  bool _closed = false;
  String? _error;

  bool get _setup => widget.request.setup;

  @override
  void initState() {
    super.initState();
    _wait = widget.request.delaySeconds.clamp(0, 600);
    if (_wait > 0) {
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return t.cancel();
        setState(() => _wait = _wait > 0 ? _wait - 1 : 0);
        if (_wait == 0) t.cancel();
      });
    }
    // 离开 App 即取消本次输入，不在后台保留 PIN 文本。
    _life = AppLifecycleListener(onHide: () => _close(null));
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    _life.dispose();
    _wipe();
    _pin.dispose();
    _again.dispose();
    super.dispose();
  }

  void _wipe() {
    _pin.clear();
    _again.clear();
  }

  /// 已交付的 input 归 gateway 所有并由其清零；未交付时在此清零。
  void _close(LocalPINInput? result) {
    if (_closed || !mounted) return result?.clear();
    var transferred = false;
    try {
      _timer?.cancel();
      _wipe();
      transferred = _popSelf(context, result);
      if (transferred) _closed = true;
    } finally {
      // 包括 Navigator 拒绝或抛出时的未移交缓冲；移交后由 gateway 清理。
      if (!transferred) result?.clear();
    }
  }

  void _submit() {
    if (_closed || _wait > 0) return;
    final a = _pin.text;
    final b = _again.text;
    if (!_pinPattern.hasMatch(a)) {
      setState(() => _error = 'PIN 需为 6–32 位数字。');
      return;
    }
    if (_setup && a != b) {
      setState(() {
        _error = '两次输入的 PIN 不一致，请重新输入确认。';
        _again.clear();
      });
      return;
    }
    Uint8List? pin;
    Uint8List? again;
    try {
      pin = Uint8List.fromList(a.codeUnits);
      if (_setup) again = Uint8List.fromList(b.codeUnits);
      final input = LocalPINInput(pin, reentry: again);
      pin = again = null;
      _close(input);
    } finally {
      // 仅在构造 input 前失败时仍持有临时字节。
      if (pin != null) pin.fillRange(0, pin.length, 0);
      if (again != null) again.fillRange(0, again.length, 0);
    }
  }

  TextField _field(TextEditingController t, String label, {bool last = false}) =>
      TextField(
        controller: t,
        autofocus: t == _pin,
        obscureText: !_show,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(32),
        ],
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        autofillHints: null,
        textInputAction: last ? TextInputAction.done : TextInputAction.next,
        decoration: InputDecoration(
          labelText: label,
          errorText: last ? _error : null,
          suffixIcon: IconButton(
            tooltip: _show ? '隐藏 PIN' : '显示 PIN',
            onPressed: () => setState(() => _show = !_show),
            icon: Icon(
              _show ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            ),
          ),
        ),
        onChanged: (_) => setState(() => _error = null),
        onSubmitted: last
            ? (_) {
                if (_ready) _submit();
              }
            : null,
      );

  bool get _ready =>
      !_closed &&
      _wait == 0 &&
      _pin.text.length >= 6 &&
      (!_setup || _again.text.length >= 6);

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop && !_closed) {
        _closed = true;
        _timer?.cancel();
        _wipe();
      }
    },
    child: _DialogFrame(
      icon: Icons.pin_outlined,
      title: _setup ? '设置本机 PIN' : _operationTitle(widget.request.operation),
      actions: [
        TextButton(onPressed: () => _close(null), child: const Text('取消')),
        FilledButton(
          onPressed: _ready ? _submit : null,
          child: Text(_wait > 0 ? '请等待 $_wait 秒' : '确认'),
        ),
      ],
      children: [
        Text(
          _setup
              ? 'PIN 只保存在本机，用于保护本机访问。请输入 6–32 位数字，忘记后无法找回。'
              : '请输入本机 PIN 以确认本次操作。PIN 只用于这一次，不会被记住。',
        ),
        if (_wait > 0)
          HNotice(
            '输入错误次数较多，请在 $_wait 秒后再试。',
            tone: HTone.warning,
            icon: Icons.timer_outlined,
          ),
        _field(_pin, _setup ? '新 PIN' : 'PIN', last: !_setup),
        if (_setup) _field(_again, '再次输入新 PIN', last: true),
      ],
    ),
  );
}

class _ForgetDialog extends StatelessWidget {
  const _ForgetDialog();

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return _DialogFrame(
      icon: Icons.phonelink_erase_outlined,
      title: '清除本机访问？',
      actions: [
        TextButton(
          onPressed: () => _popSelf(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: s.error,
            foregroundColor: s.onError,
          ),
          onPressed: () => _popSelf(context, true),
          child: const Text('清除本机访问'),
        ),
      ],
      children: const [
        Text('只会删除 PIN 保护的本机登录状态、设备钥匙和缓存数据，云端保险库不会被删除。'),
        Text('清除后需要重新登录，并在可信设备上批准，或使用恢复码重新授权。'),
        HNotice(
          '本机 PIN 无法找回，清除后将一并失效。',
          tone: HTone.warning,
          icon: Icons.warning_amber_outlined,
        ),
      ],
    );
  }
}

bool _supported(VaultController c) =>
    !c.previewMode && c.gateway is LocalProtectionGateway;

bool _canSetup(VaultController c, LocalProtectionStatus s) =>
    s.pinSetupAvailable && c.sessionStage == SessionStage.signedOut && !c.busy;

bool _needsReauth(LocalProtectionStatus s) =>
    s.mode == LocalProtectionMode.blocked || s.upgradeRequired;

HRow _setupRow(VaultController c, LocalProtectionStatus s) => HRow(
  icon: Icons.pin_outlined,
  tone: HTone.accent,
  title: '设置本机 PIN',
  subtitle: c.sessionStage == SessionStage.signedOut
      ? '此设备未设置锁屏验证，可用 PIN 保护本机访问。'
      : '请先退出登录，再在登录页设置。',
  enabled: _canSetup(c, s),
  onTap: _canSetup(c, s) ? () => unawaited(c.setupLocalPIN()) : null,
);

HRow _forgetRow(VaultController c) => HRow(
  icon: Icons.phonelink_erase_outlined,
  tone: HTone.warning,
  title: '清除本机访问',
  subtitle: '仅清除 PIN 保护的本机登录状态、设备钥匙和缓存，云端保险库不受影响。',
  enabled: !c.busy,
  onTap: c.busy ? null : () => unawaited(c.forgetLocalPIN()),
);

List<Widget> _notices(LocalProtectionStatus s) => [
  if (s.mode == LocalProtectionMode.pin && !s.pinWorkflowReady)
    const HNotice(
      '本机PIN已设置，当前版本暂不能用它访问或修改保险库。',
      tone: HTone.warning,
      icon: Icons.info_outline,
    ),
  if (_needsReauth(s))
    HNotice(
      s.pinForgetAvailable
          ? '本机保护无法继续。可以清除 PIN 保护的本机访问，然后重新登录并授权。'
          : '本机保护无法继续，此版本暂不能升级现有保护。',
      title: '需要重新授权',
      tone: HTone.warning,
      icon: Icons.gpp_maybe_outlined,
    ),
  if (s.delaySeconds > 0)
    HHint('PIN 输入错误次数较多，请约 ${s.delaySeconds} 秒后再试。', icon: Icons.timer_outlined),
];

/// 登录/注册页：仅在原生确认有资格时显示 PIN 入口，不显示推测状态。
List<Widget> localPINAccountEntries(VaultController c) {
  final s = c.localProtectionStatus;
  if (!_supported(c) || s == null) return const [];
  return [
    if (s.pinSetupAvailable)
      HSection(title: '本机保护', children: [_setupRow(c, s)]),
    if (s.pinForgetAvailable)
      HSection(title: '本机保护', children: [_forgetRow(c)]),
    ..._notices(s),
  ];
}

({String title, String subtitle, HTone tone}) _describe(LocalProtectionStatus s) =>
    switch (s.mode) {
      LocalProtectionMode.system => (
        title: '系统验证保护',
        subtitle: '访问本机保险库时需要设备密码或强生物验证。',
        tone: HTone.accent,
      ),
      LocalProtectionMode.pin => (
        title: '已设置本机 PIN',
        subtitle: s.pinWorkflowReady
            ? '访问本机保险库时需要输入 PIN。'
            : '当前版本暂不能用它访问或修改保险库。',
        tone: HTone.neutral,
      ),
      LocalProtectionMode.blocked => (
        title: '本机保护无法继续',
        subtitle: s.pinForgetAvailable
            ? '需要清除 PIN 保护的本机访问后重新授权。'
            : '此版本暂不能升级现有保护。',
        tone: HTone.warning,
      ),
      LocalProtectionMode.none => (
        title: '尚未启用本机保护',
        subtitle: switch (s.systemCapability) {
          'SYSTEM_READY' => '本机获得授权后，将使用设备密码或强生物验证保护访问。',
          'NO_SYSTEM_AUTH' => '此设备未设置锁屏验证。',
          _ => '本机保护无法继续。',
        },
        tone: s.systemCapability == 'BLOCKED' ? HTone.warning : HTone.neutral,
      ),
    };

/// 账号安全页“本机保护”状态区。
List<Widget> localProtectionSecurityEntries(VaultController c) {
  if (!_supported(c)) {
    return const [
      HSection(
        title: '本机保护',
        children: [
          HRow(
            icon: Icons.phonelink_lock_outlined,
            title: '此版本暂不支持本机保护设置',
            enabled: false,
          ),
        ],
      ),
    ];
  }
  final s = c.localProtectionStatus;
  if (s == null) {
    return [
      HSection(
        title: '本机保护',
        children: [
          HRow(
            icon: Icons.help_outline,
            title: '暂未读取到本机保护状态',
            subtitle: '状态确认前不会显示保护方式。',
            enabled: !c.busy,
            onTap: c.busy ? null : () => unawaited(c.refreshLocalProtection()),
            trailing: const Icon(Icons.refresh),
          ),
        ],
      ),
    ];
  }
  final d = _describe(s);
  return [
    HSection(
      title: '本机保护',
      children: [
        HRow(
          icon: Icons.phonelink_lock_outlined,
          tone: d.tone,
          title: d.title,
          subtitle: d.subtitle,
        ),
        if (s.pinSetupAvailable) _setupRow(c, s),
        if (s.pinForgetAvailable) _forgetRow(c),
      ],
    ),
    ..._notices(s),
  ];
}
