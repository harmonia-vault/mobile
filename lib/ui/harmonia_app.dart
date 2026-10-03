import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../vault_controller.dart';

const _seed = Color(0xFF00695C);

ThemeData _theme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  const target = Size(64, 48);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: target),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: target),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: target),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
  );
}

class HarmoniaApp extends StatefulWidget {
  const HarmoniaApp({super.key, required this.controller});

  final VaultController controller;

  @override
  State<HarmoniaApp> createState() => _HarmoniaAppState();
}

class _HarmoniaAppState extends State<HarmoniaApp> {
  late final _delegate = _Delegate(widget.controller);

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: '和弦 Harmonia',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    routerDelegate: _delegate,
    routeInformationParser: const _Parser(),
  );
}

/// Platform deep links go to the controller; the UI never pushes its own pages.
class _Parser extends RouteInformationParser<Uri> {
  const _Parser();

  @override
  Future<Uri> parseRouteInformation(RouteInformation info) async => info.uri;
}

class _Delegate extends RouterDelegate<Uri> with ChangeNotifier {
  _Delegate(this.c);

  final VaultController c;
  final _nav = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) => Navigator(
    key: _nav,
    pages: [MaterialPage<void>(child: _Root(c: c))],
    onDidRemovePage: (_) {},
  );

  /// System back reaches the page's PopScope, which calls c.goBack.
  @override
  Future<bool> popRoute() async => await _nav.currentState?.maybePop() ?? false;

  @override
  Future<void> setNewRoutePath(Uri uri) async {
    if (uri.scheme == 'harmonia') {
      c.openDeepLink(uri);
    }
  }
}

String? _blocked(VaultController c, String op) {
  if (c.busy) return '正在处理上一项操作…';
  if (!c.supports(op)) return '此操作尚未接通，当前不可用。';
  if (!c.previewMode && c.phase != ConnectionPhase.online) {
    return '需要在线连接才能修改。';
  }
  return null;
}

bool _canWrite(VaultController c, String op) => _blocked(c, op) == null;

VaultEnvironment? _find(VaultController c, String id) {
  for (final e in c.environments) {
    if (e.id == id) return e;
  }
  return null;
}

VaultDevice? _device(VaultController c, String? id) {
  for (final d in c.devices) {
    if (d.id == id) return d;
  }
  return null;
}

bool _live(AuthorizationRequest r) => r.expiresAt.isAfter(DateTime.now());

String _time(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.month}月${l.day}日 ${two(l.hour)}:${two(l.minute)}';
}

String _locKey(VaultLocation l) =>
    '${l.page.name}/${l.environmentId}/${l.deviceId}/${l.requestId}';

IconData _platformIcon(String p) =>
    RegExp('android|ios', caseSensitive: false).hasMatch(p)
    ? Icons.smartphone
    : Icons.laptop;

Widget _kv(String k, String v) => ListTile(
  contentPadding: EdgeInsets.zero,
  dense: true,
  title: Text(v),
  subtitle: Text(k),
);

String _phaseHint(ConnectionPhase phase) => switch (phase) {
  ConnectionPhase.preview => '合成演示：数据只在本机内存中，未连接任何账号。',
  ConnectionPhase.blocked => '设备信任尚未确认，当前真实操作不可用。',
  ConnectionPhase.syncing => '正在同步，结果以服务器确认为准。',
  ConnectionPhase.online => '已连接。修改需服务器确认后才会显示。',
  ConnectionPhase.offline => '离线：修改已禁用，请检查网络后刷新。',
};

IconData _phaseIcon(ConnectionPhase phase) => switch (phase) {
  ConnectionPhase.preview => Icons.visibility_outlined,
  ConnectionPhase.blocked => Icons.block,
  ConnectionPhase.syncing => Icons.sync,
  ConnectionPhase.online => Icons.cloud_done_outlined,
  ConnectionPhase.offline => Icons.cloud_off_outlined,
};

const _titles = {
  VaultPage.entry: '和弦 Harmonia',
  VaultPage.login: '登录',
  VaultPage.registration: '注册',
  VaultPage.recovery: '恢复访问',
  VaultPage.initialization: '初始化首台设备',
  VaultPage.authorization: '等待设备授权',
  VaultPage.environments: '环境',
  VaultPage.environmentDetail: '环境详情',
  VaultPage.variableEditor: '新增或编辑变量',
  VaultPage.devices: '设备',
  VaultPage.deviceDetail: '设备详情',
  VaultPage.approval: '批准设备',
  VaultPage.settings: '设置',
  VaultPage.accountSecurity: '账号安全',
  VaultPage.recoveryManagement: '恢复码管理',
};

int? _tabOf(VaultPage p) => switch (p) {
  VaultPage.environments ||
  VaultPage.environmentDetail ||
  VaultPage.variableEditor => 0,
  VaultPage.devices || VaultPage.deviceDetail || VaultPage.approval => 1,
  VaultPage.settings ||
  VaultPage.accountSecurity ||
  VaultPage.recoveryManagement => 2,
  _ => null,
};

/// The session stage gates which pages may render; null means vault locked.
VaultPage? _resolve(VaultController c) {
  final p = c.location.page;
  return switch (c.sessionStage) {
    SessionStage.signedOut =>
      const {
            VaultPage.login,
            VaultPage.registration,
            VaultPage.recovery,
          }.contains(p)
          ? p
          : VaultPage.entry,
    SessionStage.deviceAuthorization =>
      p == VaultPage.initialization ? p : VaultPage.authorization,
    SessionStage.restrictedRecovery => VaultPage.recovery,
    SessionStage.trusted || SessionStage.preview =>
      !c.canEnterVault
          ? null
          : (_tabOf(p) == null ? VaultPage.environments : p),
  };
}

Widget _body(VaultController c, VaultPage? p) {
  final l = c.location;
  return switch (p) {
    null => _Locked(c: c),
    VaultPage.entry => _EntryPage(c: c),
    VaultPage.login => _AccountForm(c: c, register: false),
    VaultPage.registration => _AccountForm(c: c, register: true),
    VaultPage.recovery => _RecoveryWizard(c: c),
    VaultPage.initialization => _InitPage(c: c),
    VaultPage.authorization => _AwaitPage(c: c),
    VaultPage.environments => _EnvList(c: c),
    VaultPage.environmentDetail => _EnvDetail(c: c, id: l.environmentId ?? ''),
    VaultPage.variableEditor => _VarEditor(c: c, id: l.environmentId ?? ''),
    VaultPage.devices => _DeviceList(c: c),
    VaultPage.deviceDetail => _DeviceDetail(
      c: c,
      deviceId: l.deviceId,
      requestId: l.requestId,
    ),
    VaultPage.approval => _Approval(
      c: c,
      deviceId: l.deviceId,
      requestId: l.requestId,
    ),
    VaultPage.settings => _Settings(c: c),
    VaultPage.accountSecurity => _AccountSecurity(c: c),
    VaultPage.recoveryManagement => _RecoveryManagement(c: c),
  };
}

class _Root extends StatefulWidget {
  const _Root({required this.c});

  final VaultController c;

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> with WidgetsBindingObserver {
  VaultController get c => widget.c;
  String? _bannerId;
  String _bannerAt = '';
  String _lastKey = '';
  Timer? _expiry;
  bool _scheduled = false;

  static const _tabs = [
    (Icons.layers_outlined, Icons.layers, '环境', VaultPage.environments),
    (Icons.devices_outlined, Icons.devices, '设备', VaultPage.devices),
    (Icons.settings_outlined, Icons.settings, '设置', VaultPage.settings),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = WidgetsBinding.instance.lifecycleState;
      if (s != null) {
        c.onLifecycleState(s);
      } else {
        c.setForeground(true);
      }
      _sync();
    });
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    WidgetsBinding.instance.removeObserver(this);
    _expiry?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      c.onLifecycleState(state);

  void _onChange() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _sync();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Drops stale popups on route/stage change and keeps at most one prompt.
  void _sync() {
    final key = '${c.sessionStage.name}|${_locKey(c.location)}';
    if (key != _lastKey) {
      _lastKey = key;
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
    final id = _bannerId;
    if (id != null) {
      final r = c.authorizationRequest(id);
      if (!c.canEnterVault ||
          !c.authorizationRequestsAvailable ||
          r == null ||
          !_live(r) ||
          _locKey(c.location) != _bannerAt) {
        _hideBanner();
      }
    }
    if (_bannerId != null ||
        !c.canEnterVault ||
        !c.authorizationRequestsAvailable) {
      return;
    }
    final r = c.takeAuthorizationPrompt();
    if (r == null || !_live(r)) return;
    _bannerId = r.id;
    _bannerAt = _locKey(c.location);
    _expiry = Timer(r.expiresAt.difference(DateTime.now()), () {
      if (mounted) _sync();
    });
    final m = ScaffoldMessenger.of(context)..clearMaterialBanners();
    m.showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.devices_other_outlined),
        content: Text(
          '“${r.deviceName}”（${r.platform}）请求访问，${_time(r.expiresAt)} 前有效。不会自动批准。',
        ),
        actions: [
          TextButton(onPressed: _hideBanner, child: const Text('稍后')),
          TextButton(
            onPressed: () {
              _hideBanner();
              c.navigate(VaultPage.deviceDetail, requestId: r.id);
            },
            child: const Text('查看详情'),
          ),
        ],
      ),
    );
  }

  void _hideBanner() {
    _expiry?.cancel();
    _expiry = null;
    if (_bannerId == null) return;
    _bannerId = null;
    c.dismissAuthorizationPrompt();
    ScaffoldMessenger.of(context).clearMaterialBanners();
  }

  void _back() {
    _hideBanner();
    c.goBack();
  }

  Widget _icon(int i, bool selected) {
    final t = _tabs[i];
    final icon = Icon(selected ? t.$2 : t.$1);
    final n = c.pendingAuthorizationCount;
    return i == 1 && c.authorizationRequestsAvailable && n > 0
        ? Badge.count(count: n, child: icon)
        : icon;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      final page = c.privacyObscured ? null : _resolve(c);
      final tab = page == null ? null : _tabOf(page);
      final wide = MediaQuery.sizeOf(context).width >= 700;
      final title = page == null
          ? '保险库不可用'
          : c.sessionStage == SessionStage.restrictedRecovery
          ? '受限恢复'
          : _titles[page]!;
      final frame = _Frame(
        c: c,
        vault: tab != null,
        child: KeyedSubtree(
          key: ValueKey('${c.sessionStage.name}|${_locKey(c.location)}'),
          child: c.privacyObscured ? _PrivacyShield(c: c) : _body(c, page),
        ),
      );
      return PopScope<Object?>(
        canPop: !c.canGoBack,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _back();
        },
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            leading: c.canGoBack ? BackButton(onPressed: _back) : null,
            title: Text(title),
            actions: [
              if (tab != null)
                IconButton(
                  tooltip: '刷新',
                  onPressed: c.busy ? null : () => unawaited(c.reload()),
                  icon: const Icon(Icons.refresh),
                ),
              if (tab == null && c.sessionStage != SessionStage.signedOut)
                TextButton(
                  onPressed: () => unawaited(c.logout()),
                  child: Text(c.previewMode ? '退出演示' : '退出登录'),
                ),
            ],
          ),
          body: SafeArea(
            top: false,
            bottom: wide || tab == null,
            child: wide && tab != null
                ? Row(
                    children: [
                      NavigationRail(
                        selectedIndex: tab,
                        labelType: NavigationRailLabelType.all,
                        onDestinationSelected: (i) => c.selectTab(_tabs[i].$4),
                        destinations: [
                          for (var i = 0; i < _tabs.length; i++)
                            NavigationRailDestination(
                              icon: _icon(i, false),
                              selectedIcon: _icon(i, true),
                              label: Text(_tabs[i].$3),
                            ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: frame),
                    ],
                  )
                : frame,
          ),
          bottomNavigationBar: tab == null || wide
              ? null
              : NavigationBar(
                  selectedIndex: tab,
                  onDestinationSelected: (i) => c.selectTab(_tabs[i].$4),
                  destinations: [
                    for (var i = 0; i < _tabs.length; i++)
                      NavigationDestination(
                        icon: _icon(i, false),
                        selectedIcon: _icon(i, true),
                        label: _tabs[i].$3,
                      ),
                  ],
                ),
        ),
      );
    },
  );
}

/// Shared progress, preview, status and error chrome above every page.
class _Frame extends StatelessWidget {
  const _Frame({required this.c, required this.vault, required this.child});

  final VaultController c;
  final bool vault;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (c.busy)
        const LinearProgressIndicator()
      else
        const SizedBox(height: 4),
      if (c.previewMode) _PreviewStrip(c: c),
      if (vault) _StatusStrip(c: c),
      if (c.error != null) _ErrorBanner(c: c),
      Expanded(child: child),
    ],
  );
}

class _PreviewStrip extends StatelessWidget {
  const _PreviewStrip({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Material(
      color: s.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Icon(Icons.visibility_outlined, color: s.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '合成演示，未连接账号。数据仅在本机内存中，不会上传。',
                style: TextStyle(color: s.onTertiaryContainer),
              ),
            ),
            TextButton(
              onPressed: () => unawaited(c.logout()),
              child: const Text('退出演示'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                const _Tag(Icons.science_outlined, '实验性 · 非生产可用'),
                _Tag(_phaseIcon(c.phase), '状态：${c.phase.label}'),
              ],
            ),
            const SizedBox(height: 4),
            Text(_phaseHint(c.phase), style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Chip(
    avatar: Icon(icon, size: 18),
    label: Text(text),
    visualDensity: VisualDensity.compact,
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      child: Material(
        color: s.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: s.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.error ?? '',
                      style: text.titleSmall?.copyWith(
                        color: s.onErrorContainer,
                      ),
                    ),
                    Text(
                      '操作未生效或结果未确认。请勿重复提交新内容；刷新查询后再决定。',
                      style: text.bodySmall?.copyWith(
                        color: s.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
              if (c.canEnterVault)
                TextButton(
                  onPressed: c.busy ? null : () => unawaited(c.reload()),
                  child: const Text('刷新'),
                ),
              IconButton(
                tooltip: '关闭错误提示',
                onPressed: c.clearError,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(
        padding: const EdgeInsets.all(16),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: children,
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          for (final w in children)
            Padding(padding: const EdgeInsets.only(top: 8), child: w),
        ],
      ),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.icon = Icons.info_outline});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    ),
  );
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.title, this.body, {this.done = false});

  final int n;
  final String title;
  final String body;
  final bool done;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: CircleAvatar(
      radius: 14,
      child: done ? const Icon(Icons.check, size: 16) : Text('$n'),
    ),
    title: Text(title),
    subtitle: Text(body),
  );
}

/// Inline two-step confirmation; no dialog lingers in the overlay.
class _Danger extends StatefulWidget {
  const _Danger({
    required this.label,
    required this.warning,
    required this.onConfirm,
  });

  final String label;
  final String warning;
  final Future<void> Function()? onConfirm;

  @override
  State<_Danger> createState() => _DangerState();
}

class _DangerState extends State<_Danger> {
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final run = widget.onConfirm;
    if (!_armed) {
      return OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: s.error),
        onPressed: run == null ? null : () => setState(() => _armed = true),
        icon: const Icon(Icons.delete_outline),
        label: Text(widget.label),
      );
    }
    return Card(
      color: s.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.warning, style: TextStyle(color: s.onErrorContainer)),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => setState(() => _armed = false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: s.error,
                    foregroundColor: s.onError,
                  ),
                  onPressed: run == null
                      ? null
                      : () {
                          setState(() => _armed = false);
                          unawaited(run());
                        },
                  child: Text('确认${widget.label}'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryPage extends StatefulWidget {
  const _EntryPage({required this.c});
  final VaultController c;
  @override
  State<_EntryPage> createState() => _EntryPageState();
}

class _EntryPageState extends State<_EntryPage> {
  late final _endpoint = TextEditingController(text: widget.c.endpoint);
  @override
  void dispose() {
    _endpoint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final url = _endpoint.text.trim();
    final parsed = Uri.tryParse(url);
    final valid =
        parsed != null && parsed.scheme == 'https' && parsed.host.isNotEmpty;
    return _Page(
      children: [
        _Section(
          title: '连接你的 Harmonia',
          children: [
            const Text('请输入自托管 HTTPS 服务地址。下一步会验证产品身份、协议兼容及公开注册能力。'),
            TextField(
              controller: _endpoint,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'HTTPS 服务地址',
                hintText: 'https://',
                errorText: url.isEmpty || valid ? null : '需要完整 HTTPS 地址',
              ),
              onChanged: (_) => setState(() {}),
            ),
            FilledButton(
              onPressed: c.busy || !valid
                  ? null
                  : () => unawaited(c.connectServer(url)),
              child: Text(c.busy ? '正在验证…' : '下一步'),
            ),
            const Text('连接失败、离线或协议不兼容时，会保留此页。连接验证不代表账号登录或设备可信。'),
          ],
        ),
        if (c.previewAvailable)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: c.busy ? null : () => unawaited(c.enterPreview()),
              icon: const Icon(Icons.developer_mode_outlined, size: 18),
              label: const Text('开发者：打开合成演示'),
            ),
          ),
      ],
    );
  }
}

class _AccountForm extends StatefulWidget {
  const _AccountForm({required this.c, required this.register});

  final VaultController c;
  final bool register;

  @override
  State<_AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends State<_AccountForm> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _show = false;

  @override
  void dispose() {
    _password.clear();
    _confirm.clear();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    setState(() {
      _password.clear(); // never retained in UI state
      _confirm.clear();
    });
    widget.register
        ? await widget.c.registerAccount(email, password)
        : await widget.c.signIn(email, password);
  }

  TextField _secret(TextEditingController t, String label) => TextField(
    controller: t,
    obscureText: !_show,
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    decoration: InputDecoration(
      labelText: label,
      suffixIcon: IconButton(
        tooltip: _show ? '隐藏密码' : '显示密码',
        onPressed: () => setState(() => _show = !_show),
        icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
      ),
    ),
    onChanged: (_) => setState(() {}),
  );

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final reg = widget.register;
    final cap = c.supports(reg ? 'registerAccount' : 'loginAccount');
    final ok =
        cap &&
        !c.busy &&
        _email.text.contains('@') &&
        _password.text.isNotEmpty &&
        (!reg || _password.text == _confirm.text);
    return _Page(
      children: [
        _Section(
          title: reg ? '注册账号' : '登录账号',
          children: [
            if (!cap)
              _Note(
                '账号${reg ? '注册' : '登录'}尚未接通（未验收），目前无法提交。',
                icon: Icons.construction_outlined,
              ),
            Text('服务地址：${c.endpoint.isEmpty ? '未设置' : c.endpoint}'),
            TextButton(
              onPressed: c.busy ? null : c.switchServer,
              child: const Text('切换服务地址'),
            ),
            if (!reg && c.registrationAvailable)
              TextButton(
                onPressed: () => c.navigate(VaultPage.registration),
                child: const Text('注册新账号'),
              ),
            if (!reg)
              TextButton(
                onPressed: () => c.navigate(VaultPage.recovery),
                child: const Text('用恢复码恢复访问'),
              ),
            if (reg)
              Text('邮箱验证：${c.emailVerificationRequired ? '需要' : '不要求'}'),
            if (reg)
              TextButton(
                onPressed: () => c.navigate(VaultPage.login),
                child: const Text('已有账号，登录'),
              ),

            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: '邮箱'),
              onChanged: (_) => setState(() {}),
            ),
            _secret(_password, '密码'),
            if (reg) _secret(_confirm, '再次输入密码'),
            FilledButton(
              onPressed: ok ? _submit : null,
              child: Text(reg ? '注册' : '登录'),
            ),
          ],
        ),
        _Section(
          title: '之后会发生什么',
          children: [
            const _Note('登录只证明账号身份，不会让本机成为可信设备。', icon: Icons.person_outline),
            _Note(
              reg
                  ? '注册后本机作为首台设备初始化：需完整重新输入安全适配器生成的新恢复码。'
                  : '非首台设备需在已授权设备上核对并批准后，才能进入保险库。',
            ),
            const _Note('密码不会被本界面保存或记录；提交后输入框立即清空。', icon: Icons.lock_outline),
          ],
        ),
      ],
    );
  }
}

class _RecoveryWizard extends StatelessWidget {
  const _RecoveryWizard({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) {
    final restricted = c.sessionStage == SessionStage.restrictedRecovery;
    return _Page(
      children: [
        if (restricted)
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: const Icon(Icons.gpp_maybe_outlined),
              title: const Text('受限恢复会话：不能访问环境与设备'),
              subtitle: Text(c.recoveryStatus),
            ),
          ),
        const _Note('恢复码不是备份，它不保存变量内容。同时丢失所有可信设备和恢复码时，旧保险库无法恢复。'),
        _Section(
          title: '恢复步骤',
          children: [
            _Step(1, '输入旧的完整恢复码', '验证后进入受限恢复会话。', done: restricted),
            const _Step(2, '完整重新输入新恢复码', '新恢复码由安全适配器生成并单独显示；重新输入只校验抄写一致。'),
            const _Step(3, '显式登记本机', '逐项选择环境、角色与有效期后登记，完成后本机才成为可信设备。'),
          ],
        ),
        _Section(
          title: '当前不可用',
          children: [
            const _Note(
              '原生恢复切片已有验证，但 Flutter 完整恢复流程尚未接通。界面不会生成或显示新恢复码，也不会显示成功。',
              icon: Icons.construction_outlined,
            ),
            FilledButton(
              onPressed: null,
              child: Text(restricted ? '继续：输入新恢复码' : '开始恢复'),
            ),
            if (restricted)
              OutlinedButton(
                onPressed: c.busy
                    ? null
                    : () => unawaited(c.queryRecoveryStatus()),
                child: const Text('查询恢复状态'),
              ),
          ],
        ),
      ],
    );
  }
}

class _InitPage extends StatelessWidget {
  const _InitPage({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) => const _Page(
    children: [
      _Section(
        title: '首台设备向导',
        children: [
          _Step(1, '账号已登录', '登录只证明身份，本机尚未可信。', done: true),
          _Step(2, '保存并完整重新输入新恢复码', '新恢复码由安全适配器生成并单独显示，请离线抄写保存。'),
          _Step(3, '初始化保险库', '完成后本机成为首台可信设备。'),
        ],
      ),
      _Note(
        '首台设备初始化尚未接通，当前无法继续；界面不会生成或显示恢复码。',
        icon: Icons.construction_outlined,
      ),
    ],
  );
}

class _AwaitPage extends StatelessWidget {
  const _AwaitPage({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      const _Section(
        title: '本机尚未成为可信设备',
        children: [
          _Step(1, '在已授权设备上打开“设备 → 批准新设备”', '需要该设备的管理权限。'),
          _Step(2, '核对配对信息', '输入本机显示的 PairID 与 8 位短码，并核对环境、角色、期限。'),
          _Step(3, '对方系统验证后批准', '服务器确认后，本机才可进入保险库。'),
          _Note('不会自动批准；在批准完成前，本机无法查看任何环境或变量。', icon: Icons.lock_outline),
        ],
      ),
      OutlinedButton(
        onPressed: c.busy ? null : () => unawaited(c.reload()),
        child: const Text('刷新状态'),
      ),
      TextButton(
        onPressed: () => c.navigate(VaultPage.initialization),
        child: const Text('这是账号的第一台设备？'),
      ),
    ],
  );
}

class _Locked extends StatelessWidget {
  const _Locked({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      _Note(_phaseHint(c.phase), icon: _phaseIcon(c.phase)),
      const _Note('保险库当前不可进入。请刷新或退出后重试。', icon: Icons.lock_outline),
      OutlinedButton(
        onPressed: c.busy ? null : () => unawaited(c.reload()),
        child: const Text('刷新'),
      ),
    ],
  );
}

String? _envNameError(String raw) {
  final n = raw.trim();
  if (n.isNotEmpty && n.runes.length > 120) return '名称最多 120 个字符';
  return null;
}

class _EnvList extends StatefulWidget {
  const _EnvList({required this.c});

  final VaultController c;

  @override
  State<_EnvList> createState() => _EnvListState();
}

class _EnvListState extends State<_EnvList> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final c = widget.c;
    final n = _name.text.trim();
    await c.createEnvironment(n);
    if (mounted && c.error == null && c.environments.any((e) => e.name == n)) {
      setState(_name.clear);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final text = Theme.of(context).textTheme;
    final why = _blocked(c, 'createEnvironment');
    final err = _envNameError(_name.text);
    return _Page(
      children: [
        Text(
          '检查点 #${c.checkpoint}',
          style: text.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        if (c.environments.isEmpty)
          const _Section(
            title: '还没有环境',
            children: [
              Text('环境是一组变量（例如“开发”“生产”）。每台设备的角色决定只读、读写或管理。'),
              Text('应用不会自动导入本机环境变量或 .env 文件。'),
            ],
          )
        else
          for (final e in c.environments)
            Card(
              child: ListTile(
                leading: const Icon(Icons.layers_outlined),
                title: Text(e.name),
                subtitle: Text('${e.role.label} · ${e.variables.length} 个变量'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => c.navigate(
                  VaultPage.environmentDetail,
                  environmentId: e.id,
                ),
              ),
            ),
        const SizedBox(height: 12),
        _Section(
          title: '新建环境',
          children: [
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: '环境名称',
                hintText: '例如 开发',
                errorText: err,
              ),
              onChanged: (_) => setState(() {}),
            ),
            FilledButton.tonalIcon(
              onPressed:
                  why == null && err == null && _name.text.trim().isNotEmpty
                  ? _create
                  : null,
              icon: const Icon(Icons.add),
              label: const Text('新建环境'),
            ),
            if (why != null) _Note(why, icon: Icons.lock_outline),
          ],
        ),
      ],
    );
  }
}

Widget _missing(VaultController c, String text) => _Page(
  children: [
    _Note(text),
    OutlinedButton(onPressed: c.goBack, child: const Text('返回')),
  ],
);

class _EnvDetail extends StatefulWidget {
  const _EnvDetail({required this.c, required this.id});

  final VaultController c;
  final String id;

  @override
  State<_EnvDetail> createState() => _EnvDetailState();
}

class _EnvDetailState extends State<_EnvDetail> {
  late final _name = TextEditingController(
    text: _find(widget.c, widget.id)?.name ?? '',
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  static String _roleNote(AccessRole role) => switch (role) {
    AccessRole.readOnly => '只读权限：可查看（值默认隐藏），不能添加、编辑或删除。',
    AccessRole.readWrite => '读写权限：可编辑变量；重命名和删除环境需要管理权限。',
    AccessRole.admin => '管理权限：可编辑变量并管理此环境。',
  };

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final env = _find(c, widget.id);
    if (env == null) return _missing(c, '该环境已不存在、已被删除或你已失去访问权限。');
    final n = _name.text.trim();
    final err = _envNameError(n);
    final why = _blocked(c, 'renameEnvironment');
    return _Page(
      children: [
        Text(env.name, style: Theme.of(context).textTheme.headlineSmall),
        _Note(
          _roleNote(env.role),
          icon: env.role == AccessRole.readOnly
              ? Icons.lock_outline
              : Icons.badge_outlined,
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                '变量（${env.variables.length}）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: env.role == AccessRole.readOnly
                  ? null
                  : () => c.navigate(
                      VaultPage.variableEditor,
                      environmentId: env.id,
                    ),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('新增或编辑'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (env.variables.isEmpty)
          const _Note('暂无变量。', icon: Icons.inbox_outlined)
        else
          for (final v in env.variables) _VarTile(key: ValueKey(v.name), v: v),
        if (env.role == AccessRole.admin) ...[
          const SizedBox(height: 12),
          _Section(
            title: '管理环境',
            children: [
              TextField(
                controller: _name,
                decoration: InputDecoration(labelText: '环境名称', errorText: err),
                onChanged: (_) => setState(() {}),
              ),
              OutlinedButton(
                onPressed:
                    why == null && err == null && n.isNotEmpty && n != env.name
                    ? () => unawaited(c.renameEnvironment(env.id, n))
                    : null,
                child: const Text('重命名'),
              ),
              if (why != null) _Note(why, icon: Icons.lock_outline),
              _Danger(
                label: '删除环境',
                warning:
                    '将删除“${env.name}”及其 ${env.variables.length} 个变量，无法撤销。已同步到其他设备的副本不会被远程清除。',
                onConfirm: _canWrite(c, 'deleteEnvironment')
                    ? () => c.deleteEnvironment(env.id)
                    : null,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _VarTile extends StatefulWidget {
  const _VarTile({super.key, required this.v});

  final VaultVariable v;

  @override
  State<_VarTile> createState() => _VarTileState();
}

class _VarTileState extends State<_VarTile> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      title: Text(widget.v.name),
      subtitle: Text(
        _revealed ? widget.v.value : '••••••••',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: _revealed ? '隐藏值' : '显示值',
        onPressed: () => setState(() => _revealed = !_revealed),
        icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility),
      ),
    ),
  );
}

String? _varNameError(String n, {required bool exists}) {
  if (n.isEmpty) return null;
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(n)) {
    return '以字母或下划线开头，仅字母、数字、下划线，最多128个字符';
  }
  if (n.toUpperCase().startsWith('__HARMONIA_')) return '“__HARMONIA_”为保留前缀';
  if (exists) return '已存在，请选择该变量进行编辑';
  return null;
}

class _VarEditor extends StatefulWidget {
  const _VarEditor({required this.c, required this.id});

  final VaultController c;
  final String id;

  @override
  State<_VarEditor> createState() => _VarEditorState();
}

class _VarEditorState extends State<_VarEditor> {
  final _name = TextEditingController();
  final _value = TextEditingController();
  String? _selected;
  bool _show = false;
  bool _unverified = false;

  @override
  void dispose() {
    _value.clear();
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  VaultVariable? _var(String? name) {
    for (final v
        in _find(widget.c, widget.id)?.variables ?? <VaultVariable>[]) {
      if (v.name == name) return v;
    }
    return null;
  }

  void _pick(String? name) => setState(() {
    _selected = name;
    _name.text = name ?? '';
    _value.text = _var(name)?.value ?? '';
    _show = false;
    _unverified = false;
  });

  /// Leaves only when the controller reports the exact value; otherwise keeps intent.
  Future<void> _save() async {
    final c = widget.c;
    final n = _name.text.trim();
    final v = _value.text;
    await c.setVariable(widget.id, n, v);
    if (!mounted) return;
    if (c.error == null && _var(n)?.value == v) {
      c.goBack();
    } else {
      setState(() => _unverified = true);
    }
  }

  Future<void> _delete() async {
    final c = widget.c;
    final n = _selected!;
    await c.deleteVariable(widget.id, n);
    if (!mounted) return;
    if (c.error == null && _var(n) == null) {
      c.goBack();
    } else {
      setState(() => _unverified = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final env = _find(c, widget.id);
    if (env == null) return _missing(c, '该环境已不存在或你已失去访问权限。');
    final names = [for (final v in env.variables) v.name];
    final gone = _selected != null && !names.contains(_selected);
    final n = _name.text.trim();
    final err = _varNameError(
      n,
      exists: _selected == null && names.contains(n),
    );
    final why = env.role == AccessRole.readOnly
        ? '只读权限，不能修改。'
        : _blocked(c, 'setVariable');
    return _Page(
      children: [
        _Note('环境：${env.name}（${env.role.label}）', icon: Icons.layers_outlined),
        DropdownButtonFormField<String?>(
          initialValue: gone ? null : _selected,
          decoration: const InputDecoration(labelText: '选择变量'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('新增变量')),
            for (final name in names)
              DropdownMenuItem<String?>(value: name, child: Text(name)),
          ],
          onChanged: c.busy ? null : _pick,
        ),
        const SizedBox(height: 12),
        if (gone)
          const _Note(
            '所选变量已不存在（可能已被其他设备删除）。',
            icon: Icons.warning_amber_rounded,
          ),
        TextField(
          controller: _name,
          readOnly: _selected != null,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: '名称',
            helperText: _selected != null ? '名称不可修改' : '例如 API_BASE_URL',
            errorText: err,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _value,
          obscureText: !_show,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          decoration: InputDecoration(
            labelText: '值',
            suffixIcon: IconButton(
              tooltip: _show ? '隐藏值' : '显示值',
              onPressed: () => setState(() => _show = !_show),
              icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
            ),
          ),
        ),
        const _Note('大小由原生层按 UTF-8 字节最终校验（整个同步数据不超过 32768 字节），此处不做长度承诺。'),
        if (_unverified)
          const _Note(
            '未能确认修改已生效。原输入已保留；请先刷新查询结果，再决定是否重试。',
            icon: Icons.warning_amber_rounded,
          ),
        if (why != null) _Note(why, icon: Icons.lock_outline),
        FilledButton(
          onPressed: why == null && err == null && n.isNotEmpty && !gone
              ? _save
              : null,
          child: const Text('保存'),
        ),
        if (_selected != null && !gone) ...[
          const SizedBox(height: 8),
          _Danger(
            label: '删除变量',
            warning: '变量 $_selected 将从“${env.name}”中移除。',
            onConfirm:
                env.role != AccessRole.readOnly &&
                    _canWrite(c, 'deleteVariable')
                ? _delete
                : null,
          ),
        ],
      ],
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      _Section(
        title: '已授权设备',
        children: [
          if (c.devices.isEmpty) const Text('暂无设备记录。'),
          for (final d in c.devices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(_platformIcon(d.platform)),
              title: Text(d.current ? '${d.name}（本机）' : d.name),
              subtitle: Text('${d.platform} · 有效期：${d.expiresLabel}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => c.navigate(VaultPage.deviceDetail, deviceId: d.id),
            ),
        ],
      ),
      _Section(
        title: '授权请求',
        children: [
          if (!c.authorizationRequestsAvailable)
            _Note(c.requestCapabilityMessage, icon: Icons.construction_outlined)
          else if (c.pendingAuthorizationRequests.isEmpty)
            const Text('没有待处理的请求。')
          else
            for (final r in c.pendingAuthorizationRequests)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(_platformIcon(r.platform)),
                title: Text(r.deviceName),
                subtitle: Text('${r.platform} · ${_time(r.expiresAt)} 前有效'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    c.navigate(VaultPage.deviceDetail, requestId: r.id),
              ),
        ],
      ),
      _Section(
        title: '批准新设备',
        children: [
          const Text('新设备显示 PairID 与 8 位短码后，可在此手动配对。'),
          FilledButton.tonalIcon(
            onPressed: () => c.navigate(VaultPage.approval),
            icon: const Icon(Icons.how_to_reg_outlined),
            label: const Text('手动配对'),
          ),
        ],
      ),
    ],
  );
}

class _DeviceDetail extends StatelessWidget {
  const _DeviceDetail({required this.c, this.deviceId, this.requestId});

  final VaultController c;
  final String? deviceId;
  final String? requestId;

  Future<void> _revoke(VaultDevice d) async {
    await c.revokeDevice(d.id);
    if (c.error == null && _device(c, d.id) == null) c.goBack();
  }

  @override
  Widget build(BuildContext context) {
    final rid = requestId;
    if (rid != null) {
      final r = c.authorizationRequest(rid);
      if (r == null || !_live(r)) return _missing(c, '该授权请求已过期、被撤销或你已无权处理。');
      return _Page(
        children: [
          _Section(
            title: '授权请求',
            children: [
              _kv('设备', r.deviceName),
              _kv('平台', r.platform),
              _kv('有效至', _time(r.expiresAt)),
              _kv('序号', '#${r.sequence}'),
              const _Note('不会自动批准。请在两台设备上核对信息后再继续。', icon: Icons.lock_outline),
              FilledButton(
                onPressed: () =>
                    c.navigate(VaultPage.approval, requestId: r.id),
                child: const Text('核对并批准'),
              ),
            ],
          ),
        ],
      );
    }
    final d = _device(c, deviceId);
    if (d == null) return _missing(c, '该设备已不存在或已被撤销。');
    return _Page(
      children: [
        _Section(
          title: d.current ? '${d.name}（本机）' : d.name,
          children: [
            _kv('平台', d.platform),
            _kv('访问范围', d.accessSummary),
            _kv('有效期', d.expiresLabel),
          ],
        ),
        _Section(
          title: '权限',
          children: [
            const Text('调整环境角色或有效期需要重新配对，并按新的角色与期限重新批准。'),
            OutlinedButton(
              onPressed: () => c.navigate(VaultPage.approval, deviceId: d.id),
              child: const Text('重新配对以调整权限'),
            ),
          ],
        ),
        _Section(
          title: '撤销',
          children: [
            const Text('撤销需服务器确认后才生效；已同步到该设备的数据无法远程清除。'),
            _Danger(
              label: '撤销设备',
              warning: d.current ? '这是本机，撤销后本机将无法继续同步。' : '确认撤销“${d.name}”？',
              onConfirm: _canWrite(c, 'revokeDevice') ? () => _revoke(d) : null,
            ),
          ],
        ),
      ],
    );
  }
}

enum _Lifetime {
  hour('1 小时', Duration(hours: 1)),
  day('1 天', Duration(days: 1)),
  untilRevoked('直到撤销', null);

  const _Lifetime(this.label, this.duration);

  final String label;
  final Duration? duration;
}

class _Approval extends StatefulWidget {
  const _Approval({required this.c, this.deviceId, this.requestId});

  final VaultController c;
  final String? deviceId;
  final String? requestId;

  @override
  State<_Approval> createState() => _ApprovalState();
}

class _ApprovalState extends State<_Approval> {
  final _pair = TextEditingController();
  final _code = TextEditingController();
  final Map<String, AccessRole?> _roles = {};
  _Lifetime _life = _Lifetime.hour;
  bool _review = false;
  bool _checked = false;
  bool _showCode = false;

  @override
  void dispose() {
    _code.clear(); // Dart strings cannot be guaranteed wiped; native owns buffers
    _pair.dispose();
    _code.dispose();
    super.dispose();
  }

  Map<String, AccessRole> get _granted => {
    for (final e in widget.c.environments)
      if (_roles[e.id] != null) e.id: _roles[e.id]!,
  };

  Future<void> _approve() async {
    final c = widget.c;
    final draft = ApprovalDraft(
      code: _code.text,
      pairingId: _pair.text.trim(),
      roles: _granted,
      lifetime: _life.duration,
    );
    setState(() {
      _code.clear();
      _review = false;
      _checked = false;
    });
    await c.approveDevice(draft);
    if (mounted && c.error == null) c.goBack();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final rid = widget.requestId;
    final req = rid == null ? null : c.authorizationRequest(rid);
    if (rid != null && (req == null || !_live(req))) {
      return _missing(c, '该授权请求已过期、被撤销或你已无权处理。');
    }
    final dev = _device(c, widget.deviceId);
    final target = req != null
        ? '${req.deviceName}（${req.platform}）'
        : dev != null
        ? '重新配对：${dev.name}'
        : '手动配对';
    final granted = _granted;
    final ok =
        RegExp(r'^[0-9]{8}$').hasMatch(_code.text) &&
        _pair.text.trim().isNotEmpty &&
        granted.isNotEmpty;
    if (_review) {
      final why = _blocked(c, 'approveDevice');
      return _Page(
        children: [
          _Section(
            title: '请逐项核对',
            children: [
              _kv('设备', target),
              _kv('PairID', _pair.text.trim()),
              for (final e in c.environments)
                if (granted[e.id] != null)
                  _kv('环境：${e.name}', granted[e.id]!.label),
              _kv('有效期', _life.label),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _checked,
                title: const Text('我已在两台设备上核对设备、环境、角色与期限'),
                onChanged: (v) => setState(() => _checked = v ?? false),
              ),
            ],
          ),
          const _Note(
            '下一步将进行系统验证（设备密码或生物识别）。服务器确认后才算批准；绝不自动批准。',
            icon: Icons.fingerprint,
          ),
          const _Note('结果未确认时请先刷新设备列表，不要重复批准。'),
          if (why != null) _Note(why, icon: Icons.lock_outline),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => setState(() => _review = false),
                child: const Text('返回修改'),
              ),
              FilledButton(
                onPressed: _checked && why == null ? _approve : null,
                child: const Text('系统验证并批准'),
              ),
            ],
          ),
        ],
      );
    }
    return _Page(
      children: [
        _Note(
          req == null && dev == null
              ? '手动配对：PairID 只是公开配对标识，不代表服务器上存在待批准请求。'
              : '目标：$target',
          icon: Icons.devices_other_outlined,
        ),
        _Section(
          title: '配对信息',
          children: [
            TextField(
              controller: _pair,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'PairID（公开）'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _code,
              obscureText: !_showCode,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(8),
              ],
              decoration: InputDecoration(
                labelText: '8 位秘密短码',
                helperText: '新设备上显示；保留前导零，结束后清空',
                suffixIcon: IconButton(
                  tooltip: _showCode ? '隐藏' : '显示',
                  onPressed: () => setState(() => _showCode = !_showCode),
                  icon: Icon(
                    _showCode ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const _Note('短码只在本机参与配对计算，不发送到服务器。', icon: Icons.lock_outline),
          ],
        ),
        _Section(
          title: '各环境权限',
          children: [
            if (c.environments.isEmpty) const Text('没有可授权的环境。'),
            for (final e in c.environments)
              Row(
                children: [
                  Expanded(child: Text(e.name)),
                  DropdownButton<AccessRole?>(
                    value: _roles[e.id],
                    hint: const Text('无访问'),
                    onChanged: (v) => setState(() => _roles[e.id] = v),
                    items: [
                      const DropdownMenuItem<AccessRole?>(
                        value: null,
                        child: Text('无访问'),
                      ),
                      for (final r in AccessRole.values)
                        DropdownMenuItem<AccessRole?>(
                          value: r,
                          child: Text(r.label),
                        ),
                    ],
                  ),
                ],
              ),
            Text('有效期', style: Theme.of(context).textTheme.titleSmall),
            SegmentedButton<_Lifetime>(
              segments: [
                for (final l in _Lifetime.values)
                  ButtonSegment(value: l, label: Text(l.label)),
              ],
              selected: {_life},
              onSelectionChanged: (s) => setState(() => _life = s.first),
            ),
            const Text('“直到撤销”为永久有效，直到在设备详情中撤销。'),
          ],
        ),
        FilledButton(
          onPressed: ok
              ? () => setState(() {
                  _review = true;
                  _checked = false;
                })
              : null,
          child: const Text('下一步：核对'),
        ),
      ],
    );
  }
}

class _Settings extends StatelessWidget {
  const _Settings({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: const Text('账号安全'),
          subtitle: const Text('登录与设备信任、恢复码管理'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => c.navigate(VaultPage.accountSecurity),
        ),
      ),
      _Section(
        title: '服务',
        children: [
          _kv('服务地址', c.previewMode ? '合成演示，未连接' : c.endpoint),
          _kv('连接状态', c.phase.label),
        ],
      ),
      const _Section(
        title: '实验性实现边界',
        children: [
          _Note('加密、设备配对与恢复由独立安全适配器提供，默认失败关闭。', icon: Icons.science_outlined),
          _Note(
            '真实保险库尚未就绪；未经安全审计，请勿用于生产凭据。',
            icon: Icons.warning_amber_rounded,
          ),
        ],
      ),
      OutlinedButton.icon(
        onPressed: () => unawaited(c.logout()),
        icon: const Icon(Icons.logout),
        label: Text(c.previewMode ? '退出演示' : '退出登录'),
      ),
    ],
  );
}

class _AccountSecurity extends StatelessWidget {
  const _AccountSecurity({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      const _Section(
        title: '身份与设备信任',
        children: [
          _Note(
            '账号登录只证明身份；本机能访问保险库，是因为它已被批准为可信设备。',
            icon: Icons.person_outline,
          ),
          _Note('撤销其他设备或调整权限请前往“设备”。'),
          _Note('App 锁与 PIN 密钥保护尚未实现；PIN 不因系统认证取消、失败或临时锁定而启用。'),
          SwitchListTile(
            value: false,
            onChanged: null,
            title: Text('进入 App 时验证'),
            subtitle: Text('需要原生安全存储、限流和真实密钥 provider，当前不可用。'),
          ),
        ],
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.health_and_safety_outlined),
          title: const Text('恢复码管理'),
          subtitle: Text(c.recoveryStatus),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => c.navigate(VaultPage.recoveryManagement),
        ),
      ),
    ],
  );
}

class _RecoveryManagement extends StatelessWidget {
  const _RecoveryManagement({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      Card(
        color: Theme.of(context).colorScheme.secondaryContainer,
        margin: const EdgeInsets.only(bottom: 12),
        child: ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: const Text('恢复状态'),
          subtitle: Text(c.recoveryStatus),
        ),
      ),
      const _Section(
        title: '恢复不是备份',
        children: [
          Text('恢复码用于在你仍持有它时重新获得保险库访问，它不保存变量内容的副本。'),
          Text('如果同时丢失所有已授权设备和恢复码，旧保险库将无法恢复，只能新建。'),
        ],
      ),
      _Section(
        title: '轮换恢复码',
        children: [
          const Text('新恢复码由安全适配器生成并单独显示，需完整重新输入。旧码在服务器确认原子切换后才失效。'),
          const _Note(
            '轮换流程尚未接通，当前不可用；界面不会生成或显示新恢复码。',
            icon: Icons.construction_outlined,
          ),
          const FilledButton(onPressed: null, child: Text('开始轮换')),
          const _Note('结果不确定时，请先查询再决定是否重试。'),
          OutlinedButton(
            onPressed: c.busy ? null : () => unawaited(c.queryRecoveryStatus()),
            child: const Text('查询恢复状态'),
          ),
        ],
      ),
    ],
  );
}

class _PrivacyShield extends StatelessWidget {
  const _PrivacyShield({required this.c});
  final VaultController c;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 48),
          const SizedBox(height: 16),
          Text(c.privacyLocked ? '应用已锁定' : '隐私保护中'),
          const SizedBox(height: 12),
          Text(c.privacyLocked ? '解锁只恢复应用入口，不等于账号登录或设备授权。' : '返回应用前台后继续。'),
          if (c.privacyLocked)
            FilledButton(
              onPressed: c.privacyLockAvailable && !c.busy
                  ? () => unawaited(c.unlockPrivacy())
                  : null,
              child: const Text('验证后解锁'),
            ),
          if (c.error != null) Text(c.error!),
          if (c.privacyLocked && !c.privacyLockAvailable)
            const Text('原生 App 锁与 PIN 密钥保护尚未接通，当前不能解锁。'),
        ],
      ),
    ),
  );
}
