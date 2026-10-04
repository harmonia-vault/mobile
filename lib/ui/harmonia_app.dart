import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../native/native_pin_adapter.dart' show LocalProtectionGateway;
import '../vault_controller.dart';
import '../security/sensitive_input_guard.dart';
import 'design_system.dart';
import 'local_pin_ui.dart';
import 'recovery_ui.dart';

class HarmoniaApp extends StatefulWidget {
  const HarmoniaApp({super.key, required this.controller});

  final VaultController controller;

  @override
  State<HarmoniaApp> createState() => _HarmoniaAppState();
}

class _HarmoniaAppState extends State<HarmoniaApp>
    with WidgetsBindingObserver {
  late final _delegate = _Delegate(widget.controller);

  bool get _localProtection =>
      widget.controller.gateway is LocalProtectionGateway;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller.gateway case final LocalProtectionGateway g) {
      // Dialogs only collect one-shot input; the gateway owns validation.
      g.bindLocalPINCallbacks(
        prompt: (request) async {
          final ctx = mounted ? _delegate._nav.currentContext : null;
          return ctx == null ? null : showLocalPINPrompt(ctx, request);
        },
        confirmForget: () async {
          final ctx = mounted ? _delegate._nav.currentContext : null;
          return ctx != null && await showLocalPINForgetPrompt(ctx);
        },
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = widget.controller;
    if (state == AppLifecycleState.resumed && _localProtection && !c.busy) {
      unawaited(c.refreshLocalProtection());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    theme: harmoniaTheme(Brightness.light),
    darkTheme: harmoniaTheme(Brightness.dark),
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
  if (!c.supports(op)) return '此版本暂不支持该操作。';
  if (!c.previewMode && c.phase != ConnectionPhase.online) {
    return '需要联网才能修改。';
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
    ? Icons.smartphone_outlined
    : Icons.laptop_outlined;

IconData _roleIcon(AccessRole r) => switch (r) {
  AccessRole.readOnly => Icons.visibility_outlined,
  AccessRole.readWrite => Icons.edit_outlined,
  AccessRole.admin => Icons.admin_panel_settings_outlined,
};

String _phaseLabel(ConnectionPhase phase) => switch (phase) {
  ConnectionPhase.preview => '演示模式',
  ConnectionPhase.blocked => '暂不可用',
  ConnectionPhase.syncing => '正在同步',
  ConnectionPhase.online => '已连接',
  ConnectionPhase.offline => '离线',
};

String _phaseHint(ConnectionPhase phase) => switch (phase) {
  ConnectionPhase.preview => '示例数据仅保存在本机内存，未连接任何账号。',
  ConnectionPhase.blocked => '本机的设备信任尚未确认，暂时无法修改数据。',
  ConnectionPhase.syncing => '正在同步，结果以服务器确认为准。',
  ConnectionPhase.online => '已连接。修改经服务器确认后才会显示。',
  ConnectionPhase.offline => '当前离线，仅可查看。请检查网络后刷新。',
};

IconData _phaseIcon(ConnectionPhase phase) => switch (phase) {
  ConnectionPhase.preview => Icons.visibility_outlined,
  ConnectionPhase.blocked => Icons.block,
  ConnectionPhase.syncing => Icons.sync,
  ConnectionPhase.online => Icons.cloud_done_outlined,
  ConnectionPhase.offline => Icons.cloud_off_outlined,
};

HTone _phaseTone(ConnectionPhase phase) => switch (phase) {
  ConnectionPhase.blocked || ConnectionPhase.offline => HTone.warning,
  ConnectionPhase.online => HTone.success,
  _ => HTone.neutral,
};

const _titles = {
  VaultPage.entry: '',
  VaultPage.login: '',
  VaultPage.registration: '',
  VaultPage.emailProof: '',
  VaultPage.recovery: '',
  VaultPage.initialization: '',
  VaultPage.authorization: '',
  VaultPage.environments: '环境',
  VaultPage.environmentDetail: '环境详情',
  VaultPage.variableEditor: '编辑变量',
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
            VaultPage.emailProof,
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
    VaultPage.emailProof => _EmailProofPage(c: c),
    VaultPage.recovery => RecoveryPanel(controller: c),
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
  Widget? _formBody;
  String? _formScope;
  VaultPage? _formPage;

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
    _formBody = null;
    _formScope = null;
    _formPage = null;
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
          '“${r.deviceName}”（${r.platform}）请求访问，${_time(r.expiresAt)} 前有效。需要你核对后手动批准。',
        ),
        actions: [
          TextButton(onPressed: _hideBanner, child: const Text('稍后')),
          TextButton(
            onPressed: () {
              _hideBanner();
              c.navigate(VaultPage.deviceDetail, requestId: r.id);
            },
            child: const Text('查看'),
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
      final scheme = Theme.of(context).colorScheme;
      final scope = '${c.sensitiveFormScope}|${_locKey(c.location)}';
      final keepForm =
          c.privacyObscured && c.retainSensitiveForm && _formScope == scope;
      final page = c.privacyObscured
          ? (keepForm ? _formPage : null)
          : _resolve(c);
      if (!c.privacyObscured) {
        _formBody = _body(c, page);
        _formScope = scope;
        _formPage = page;
      } else if (!keepForm) {
        _formBody = null;
        _formScope = null;
        _formPage = null;
      }
      final tab = page == null ? null : _tabOf(page);
      // Tab roots render their own large page title.
      final root = tab != null && page == _tabs[tab].$4;
      final wide = MediaQuery.sizeOf(context).width >= HSize.wide;
      final frame = _Frame(
        c: c,
        vault: tab != null,
        child: KeyedSubtree(
          key: ValueKey(scope),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Offstage(
                offstage: c.privacyObscured,
                child: ExcludeFocus(
                  excluding: c.privacyObscured,
                  child: ExcludeSemantics(
                    excluding: c.privacyObscured,
                    child: IgnorePointer(
                      ignoring: c.privacyObscured,
                      child: TickerMode(
                        enabled: !c.privacyObscured,
                        child: _formBody ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
              if (c.privacyObscured) _PrivacyShield(c: c),
            ],
          ),
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
            title: tab != null && !root ? Text(_titles[page]!) : null,
            actions: [
              if (tab != null)
                IconButton(
                  tooltip: '刷新',
                  onPressed: c.busy ? null : () => unawaited(c.reload()),
                  icon: const Icon(Icons.refresh),
                ),
              if (tab == null &&
                  c.sessionStage != SessionStage.signedOut &&
                  !c.previewMode)
                TextButton(
                  onPressed: () => unawaited(c.logout()),
                  child: const Text('退出登录'),
                ),
              const SizedBox(width: HSpace.xs),
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
                      const VerticalDivider(width: HSize.hairline),
                      Expanded(child: frame),
                    ],
                  )
                : frame,
          ),
          bottomNavigationBar: tab == null || wide
              ? null
              : DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: scheme.hHairline,
                        width: HSize.stroke,
                      ),
                    ),
                  ),
                  child: HNavBar(
                    selectedIndex: tab,
                    onSelected: (i) => c.selectTab(_tabs[i].$4),
                    items: [
                      for (var i = 0; i < _tabs.length; i++)
                        (
                          icon: _icon(i, false),
                          selectedIcon: _icon(i, true),
                          label: _tabs[i].$3,
                        ),
                    ],
                  ),
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
        const LinearProgressIndicator(minHeight: HSpace.xxs)
      else
        const SizedBox(height: HSpace.xxs),
      if (c.previewMode) _PreviewStrip(c: c),
      if (vault && !c.previewMode && c.phase != ConnectionPhase.online)
        _StatusStrip(c: c),
      if (c.error != null) _ErrorBanner(c: c),
      Expanded(child: child),
    ],
  );
}

/// 统一演示模式水印：只在 previewMode 下出现在每个页面顶部。
class _PreviewStrip extends StatelessWidget {
  const _PreviewStrip({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Semantics(
      container: true,
      label: '演示模式',
      child: Material(
        color: s.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            HSpace.lg,
            HSpace.xxs,
            HSpace.sm,
            HSpace.xxs,
          ),
          child: Row(
            children: [
              Icon(
                Icons.visibility_outlined,
                size: HSize.iconSmall,
                color: s.onTertiaryContainer,
              ),
              const SizedBox(width: HSpace.sm),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '演示模式',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: s.onTertiaryContainer,
                        ),
                      ),
                      TextSpan(
                        text: '  示例数据，不会上传',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: s.onTertiaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: s.onTertiaryContainer,
                ),
                onPressed: () => unawaited(c.logout()),
                child: const Text('退出演示'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(HSpace.lg, HSpace.sm, HSpace.lg, 0),
    child: HNotice(
      _phaseHint(c.phase),
      title: _phaseLabel(c.phase),
      icon: _phaseIcon(c.phase),
      tone: _phaseTone(c.phase),
    ),
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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(HSpace.lg, HSpace.sm, HSpace.lg, 0),
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            HSpace.md,
            HSpace.md,
            HSpace.xs,
            HSpace.xs,
          ),
          decoration: BoxDecoration(
            color: s.errorContainer,
            borderRadius: BorderRadius.circular(HRadius.md),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: HSpace.xxs),
                child: Icon(
                  Icons.error_outline,
                  size: HSize.icon,
                  color: s.onErrorContainer,
                ),
              ),
              const SizedBox(width: HSpace.md),
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
                    const SizedBox(height: HSpace.xxs),
                    Text(
                      '操作未生效或结果未确认。请勿重复提交新内容，先刷新再决定。',
                      style: text.bodySmall?.copyWith(
                        color: s.onErrorContainer,
                      ),
                    ),
                    if (c.canEnterVault)
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: s.onErrorContainer,
                          padding: EdgeInsets.zero,
                        ),
                        onPressed: c.busy ? null : () => unawaited(c.reload()),
                        child: const Text('刷新'),
                      )
                    else
                      const SizedBox(height: HSpace.sm),
                  ],
                ),
              ),
              IconButton(
                tooltip: '关闭错误提示',
                color: s.onErrorContainer,
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

/// 一组竖排脚注。
Widget _hints(List<Widget> children) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  spacing: HSpace.sm,
  children: children,
);

/// 竖排按钮组：主按钮在上，次要按钮在下。
Widget _actions(List<Widget> children) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  spacing: HSpace.sm,
  children: children,
);

Text _muted(BuildContext context, String text) => Text(
  text,
  style: Theme.of(context).textTheme.bodyMedium
      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
);

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
    return HPage(
      narrow: true,
      children: [
        const HBrandHero(
          caption: '连接到 Harmonia',
          body: '输入你自托管的服务地址。连接后再登录或创建账号。',
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: HSpace.md,
          children: [
            TextField(
              controller: _endpoint,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: '服务地址',
                hintText: 'https://',
                prefixIcon: const Icon(Icons.dns_outlined),
                errorText: url.isEmpty || valid ? null : '请输入完整的 HTTPS 地址',
              ),
              onChanged: (_) => setState(() {}),
            ),
            FilledButton(
              onPressed: c.busy || !valid
                  ? null
                  : () => unawaited(c.connectServer(url)),
              child: Text(c.busy ? '正在验证…' : '下一步'),
            ),
          ],
        ),
        const HHint(
          '仅支持 HTTPS。连接成功不等于已登录，也不会让本机成为可信设备。',
          icon: Icons.lock_outline,
        ),
        if (c.previewAvailable)
          Center(
            child: TextButton.icon(
              onPressed: c.busy ? null : () => unawaited(c.enterPreview()),
              icon: const Icon(Icons.visibility_outlined, size: HSize.icon),
              label: const Text('打开演示模式'),
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

  late final SensitiveInputGuard _sensitiveInputs;
  @override
  void initState() {
    super.initState();
    _sensitiveInputs = SensitiveInputGuard(
      [_password, _confirm],
      onCleared: () {
        if (mounted) {
          setState(() {
            _show = false;
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _sensitiveInputs.dispose();
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
        icon: Icon(
          _show ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
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
    final rows = <Widget>[
      if (c.supports('restoreSession'))
        HRow(
          icon: Icons.phonelink_lock_outlined,
          title: '打开本机已授权的保险库',
          subtitle: '需要系统验证',
          enabled: !c.busy,
          onTap: () => unawaited(c.unlockSavedDevice()),
        ),
      if (c.supports('queryInitialization'))
        HRow(
          icon: Icons.restart_alt,
          title: '继续本机的首台设备初始化',
          enabled: !c.busy,
          onTap: () => unawaited(c.resumeInitialization()),
        ),
      if (!reg)
        HRow(
          icon: Icons.health_and_safety_outlined,
          title: '使用恢复码恢复访问',
          onTap: () => c.navigate(VaultPage.recovery),
        ),
    ];
    return HPage(
      narrow: true,
      children: [
        HBrandHero(
          caption: reg ? '创建账号' : '登录',
          body: reg ? '在此服务上创建新账号。' : '环境变量，多端同步。使用你在此服务上的账号登录。',
        ),
        if (!cap)
          HNotice(
            '此版本暂不支持在 App 内${reg ? '注册' : '登录'}。',
            tone: HTone.warning,
            icon: Icons.construction_outlined,
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
        if (reg && c.emailVerificationRequired)
          const HHint('注册后需要验证邮箱。', icon: Icons.mark_email_read_outlined),
        _actions([
          FilledButton(
            onPressed: ok ? _submit : null,
            child: Text(reg ? '注册' : '登录'),
          ),
          if (!reg && c.registrationAvailable)
            OutlinedButton(
              onPressed: () => c.navigate(VaultPage.registration),
              child: const Text('注册新账号'),
            ),
          if (reg)
            OutlinedButton(
              onPressed: () => c.navigate(VaultPage.login),
              child: const Text('已有账号？登录'),
            ),
        ]),
        HNotice(
          reg
              ? '注册只创建账号。本机随后作为首台设备初始化，需要完整重新输入新生成的恢复码。'
              : '登录只确认账号身份。新设备需要在已授权的设备上批准后，才能查看保险库。',
          icon: Icons.verified_user_outlined,
        ),
        if (rows.isNotEmpty) HSection(children: rows),
        ...localPINAccountEntries(c),
        const HHint('密码不会被保存，提交后输入框立即清空。', icon: Icons.lock_outline),
        HSurface(
          child: HRow(
            icon: Icons.dns_outlined,
            label: '服务地址',
            title: c.endpoint.isEmpty ? '未设置' : c.endpoint,
            trailing: TextButton(
              style: hChipButton(Theme.of(context).colorScheme),
              onPressed: c.busy ? null : c.switchServer,
              child: const Text('更换'),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmailProofPage extends StatefulWidget {
  const _EmailProofPage({required this.c});
  final VaultController c;
  @override
  State<_EmailProofPage> createState() => _EmailProofPageState();
}

class _EmailProofPageState extends State<_EmailProofPage> {
  final _challenge = TextEditingController();
  final _token = TextEditingController();
  late final SensitiveInputGuard _sensitiveInputs;
  @override
  void initState() {
    super.initState();
    _sensitiveInputs = SensitiveInputGuard(
      [_token, _challenge],
      onCleared: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _sensitiveInputs.dispose();
    _token.clear();
    _challenge.clear();
    _token.dispose();
    _challenge.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final token = _token.text.trim();
    final challenge = _challenge.text.trim();
    _token.clear();
    _challenge.clear();
    await widget.c.verifyRegistrationEmail(challenge, token);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return HPage(
      narrow: true,
      children: [
        const HHeader(
          icon: Icons.mark_email_unread_outlined,
          title: '验证邮箱',
          body: '账号已创建。请输入验证邮件中的验证 ID 和验证码。',
        ),
        if (!c.supports('verifyEmail'))
          const HNotice(
            '此版本暂不支持在 App 内验证邮箱。',
            tone: HTone.warning,
            icon: Icons.construction_outlined,
          ),
        HSection(
          form: true,
          children: [
            TextField(
              controller: _challenge,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: '验证 ID'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _token,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              decoration: const InputDecoration(labelText: '验证码'),
              onChanged: (_) => setState(() {}),
            ),
            FilledButton(
              onPressed:
                  !c.busy &&
                      c.supports('verifyEmail') &&
                      _challenge.text.trim().isNotEmpty &&
                      _token.text.trim().isNotEmpty
                  ? _submit
                  : null,
              child: const Text('系统验证并提交'),
            ),
          ],
        ),
        _hints(const [
          HHint('验证邮箱不会让本机成为可信设备。', icon: Icons.lock_outline),
          HHint('暂不支持在 App 内重新发送验证邮件。'),
          HHint('结果不明确或验证码已使用过时，请先用原账号重新登录确认状态，不要重新注册。'),
        ]),
        OutlinedButton(
          onPressed: c.busy ? null : () => c.navigate(VaultPage.login),
          child: const Text('重新登录确认状态'),
        ),
      ],
    );
  }
}

class _InitPage extends StatefulWidget {
  const _InitPage({required this.c});
  final VaultController c;
  @override
  State<_InitPage> createState() => _InitPageState();
}

class _InitPageState extends State<_InitPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController(text: '初始环境');
  final _fullCode = TextEditingController();
  bool _showCode = false;
  late final SensitiveInputGuard _sensitiveInputs;
  @override
  void initState() {
    super.initState();
    _sensitiveInputs = SensitiveInputGuard(
      [_password, _fullCode],
      onCleared: () {
        if (mounted) {
          setState(() {
            _showCode = false;
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _sensitiveInputs.dispose();
    _password.clear();
    _fullCode.clear();
    _email.dispose();
    _password.dispose();
    _name.dispose();
    _fullCode.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    final password = _password.text;
    _password.clear();
    await widget.c.beginInitialization(
      _email.text.trim(),
      password,
      _name.text.trim(),
    );
  }

  Future<void> _complete() async {
    final reentry = _fullCode.text;
    _fullCode.clear();
    await widget.c.completeInitialization(reentry);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final theme = Theme.of(context);
    final begun = c.initializationState != 'none';
    final canBegin =
        c.supports('beginInitialization') &&
        !c.busy &&
        !begun &&
        _email.text.contains('@') &&
        _password.text.isNotEmpty &&
        _name.text.trim().isNotEmpty &&
        _envNameError(_name.text) == null;
    return HPage(
      narrow: true,
      children: [
        const HHeader(
          icon: Icons.phonelink_setup_outlined,
          title: '设置首台设备',
          body: '本机还不是可信设备。初始化需要重新验证账号密码和系统身份，完成并通过验证后才能进入保险库。',
        ),
        if (!begun) ...[
          if (!c.supports('beginInitialization'))
            const HNotice(
              '此版本暂不支持首台设备初始化。',
              tone: HTone.warning,
              icon: Icons.construction_outlined,
            ),
          HSection(
            form: true,
            children: [
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '账号邮箱'),
                onChanged: (_) => setState(() {}),
              ),
              TextField(
                controller: _password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: const InputDecoration(labelText: '账号密码'),
                onChanged: (_) => setState(() {}),
              ),
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: '首个环境名称',
                  errorText: _envNameError(_name.text),
                ),
                onChanged: (_) => setState(() {}),
              ),
              FilledButton(
                onPressed: canBegin ? _begin : null,
                child: const Text('生成新恢复码'),
              ),
            ],
          ),
        ],
        if (begun)
          HSection(
            title: '保存恢复码',
            form: true,
            children: [
              _muted(context, '请离线抄写并妥善保存本次恢复码。它不会以明文上传，也不会自动填入下方输入框。'),
              if (c.initializationCode != null) ...[
                Container(
                  padding: const EdgeInsets.all(HSpace.lg),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(HRadius.md),
                  ),
                  child: SelectableText(
                    _showCode ? c.initializationCode! : '••••••••',
                    style: hMono(theme.textTheme.titleMedium),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _showCode = !_showCode),
                  icon: Icon(
                    _showCode
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  label: Text(_showCode ? '隐藏恢复码' : '显示恢复码'),
                ),
              ] else
                const HNotice('本次恢复码已不在内存中。请使用你已保存的完整恢复码，并查询原初始化状态，不要重新开始。'),
              TextField(
                controller: _fullCode,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: const InputDecoration(labelText: '完整重新输入恢复码'),
                onChanged: (_) => setState(() {}),
              ),
              FilledButton(
                onPressed:
                    !c.busy &&
                        c.supports('completeInitialization') &&
                        _fullCode.text.isNotEmpty
                    ? _complete
                    : null,
                child: const Text('核验并完成初始化'),
              ),
              OutlinedButton(
                onPressed: !c.busy && c.supports('queryInitialization')
                    ? () => unawaited(c.queryInitialization())
                    : null,
                child: const Text('查询初始化状态'),
              ),
              HHint('当前状态：${c.initializationState}'),
            ],
          ),
      ],
    );
  }
}

class _AwaitPage extends StatelessWidget {
  const _AwaitPage({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) => HPage(
    narrow: true,
    children: [
      const HHeader(
        icon: Icons.hourglass_top_rounded,
        title: '等待授权',
        body: '本机还不是可信设备。请在已授权的设备上批准本机。',
      ),
      const HSection(
        title: '如何批准',
        form: true,
        children: [
          HStep(1, '在已授权设备上打开“设备 → 批准新设备”', '该设备需要管理权限。'),
          HStep(2, '输入配对信息', '输入本机显示的配对 ID 与 8 位短码，并核对环境、角色和有效期。'),
          HStep(3, '在对方设备上完成系统验证', '服务器确认后，本机才能进入保险库。'),
        ],
      ),
      const HHint('不会自动批准。批准完成前，本机无法查看任何环境或变量。', icon: Icons.lock_outline),
      _actions([
        FilledButton(
          onPressed: c.busy ? null : () => unawaited(c.reload()),
          child: const Text('刷新状态'),
        ),
        TextButton(
          onPressed: () => c.navigate(VaultPage.initialization),
          child: const Text('这是账号的第一台设备？'),
        ),
      ]),
    ],
  );
}

class _Locked extends StatelessWidget {
  const _Locked({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = c.approvalProgress;
    return HPage(
      narrow: true,
      children: [
        const HHeader(
          icon: Icons.lock_outline,
          tone: HTone.neutral,
          title: '保险库暂不可用',
          body: '请刷新，或退出后重试。',
        ),
        HNotice(
          _phaseHint(c.phase),
          title: _phaseLabel(c.phase),
          icon: _phaseIcon(c.phase),
          tone: _phaseTone(c.phase),
        ),
        if (p.state != 'none')
          HSection(
            title: '设备审批进度',
            children: [
              HKeyValue('配对 ID', p.pairingId, mono: true, selectable: true),
              HKeyValue(
                '状态',
                p.state == 'approved'
                    ? '管理设备已批准，等待新设备完成'
                    : p.state == 'complete'
                    ? '双方均已完成'
                    : '结果待确认，只能沿原配对 ID 继续',
              ),
              Padding(
                padding: const EdgeInsets.all(HSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: HSpace.sm,
                  children: [
                    const HHint('只会沿用原配对 ID 继续，不会重新输入短码、修改环境范围或产生新签名。'),
                    const HHint('“已批准”仅表示管理设备已批准，不代表新设备已完成登记。'),
                    const SizedBox(height: HSpace.xs),
                    FilledButton(
                      onPressed:
                          !c.busy && c.supports('retryApproval') && p.canRetry
                          ? () => unawaited(c.retryApproval())
                          : null,
                      child: const Text('沿原配对 ID 查询并继续'),
                    ),
                    OutlinedButton(
                      onPressed: !c.busy && c.supports('queryApproval')
                          ? () => unawaited(c.queryApproval())
                          : null,
                      child: const Text('查询审批状态'),
                    ),
                    OutlinedButton(
                      onPressed:
                          !c.busy && c.supports('cancelApproval') && p.canCancel
                          ? () => unawaited(c.cancelApproval())
                          : null,
                      child: const Text('取消未提交的审批'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        if (c.supports('businessPendingInfo'))
          HSection(
            title: '本机未完成的操作',
            children: [
              for (final item in c.businessPending)
                Padding(
                  padding: const EdgeInsets.all(HSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: HSpace.xs,
                    children: [
                      Text(item.operation, style: theme.textTheme.titleSmall),
                      Text(
                        '状态 ${item.state} · 序号 ${item.sequence} · ${item.applied ? '已应用' : '未应用'}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      SelectableText(
                        item.id,
                        style: hMono(
                          theme.textTheme.bodySmall,
                        ).copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: HSpace.xs),
                      FilledButton.tonal(
                        onPressed:
                            !c.busy &&
                                item.canRetry &&
                                c.supports('retryBusinessOperation')
                            ? () => unawaited(c.retryBusinessPending(item.id))
                            : null,
                        child: const Text('沿原 ID 查询并继续'),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(HSpace.sm),
                child: TextButton(
                  onPressed: c.busy
                      ? null
                      : () => unawaited(c.queryBusinessPending()),
                  child: const Text('查询本机未完成的操作'),
                ),
              ),
            ],
          ),
        OutlinedButton(
          onPressed: c.busy ? null : () => unawaited(c.reload()),
          child: const Text('刷新'),
        ),
      ],
    );
  }
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
    final why = _blocked(c, 'createEnvironment');
    final err = _envNameError(_name.text);
    return HPage(
      children: [
        const HPageTitle('环境'),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: HSpace.md,
            children: [
              Expanded(
                child: HStat(
                  label: '全部环境',
                  value: '${c.environments.length}',
                ),
              ),
              Expanded(
                child: HStat(
                  label: '状态',
                  value: _phaseLabel(c.phase),
                  icon: _phaseIcon(c.phase),
                  tone: _phaseTone(c.phase),
                ),
              ),
            ],
          ),
        ),
        if (c.environments.isEmpty)
          const HSurface(
            child: HEmpty(
              icon: Icons.layers_outlined,
              title: '还没有环境',
              body: '环境是一组变量，例如“开发”或“生产”。每台设备在各环境中的角色决定它能查看还是修改。不会自动导入本机环境变量或 .env 文件。',
            ),
          )
        else
          for (final e in c.environments)
            HEnvCard(
              name: e.name,
              count: e.variables.length,
              role: e.role.label,
              roleIcon: _roleIcon(e.role),
              readOnly: e.role == AccessRole.readOnly,
              onTap: () => c.navigate(
                VaultPage.environmentDetail,
                environmentId: e.id,
              ),
            ),
        HSection(
          title: '新建环境',
          form: true,
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
            FilledButton.icon(
              onPressed:
                  why == null && err == null && _name.text.trim().isNotEmpty
                  ? _create
                  : null,
              icon: const Icon(Icons.add),
              label: const Text('新建环境'),
            ),
            if (why != null) HHint(why, icon: Icons.lock_outline),
          ],
        ),
      ],
    );
  }
}

Widget _missing(VaultController c, String text) => HPage(
  narrow: true,
  children: [
    HSurface(
      child: HEmpty(icon: Icons.search_off_outlined, title: text),
    ),
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
    AccessRole.readOnly => '只读：可以查看变量（值默认隐藏），不能新增、编辑或删除。',
    AccessRole.readWrite => '读写：可以编辑变量；重命名或删除环境需要管理权限。',
    AccessRole.admin => '管理：可以编辑变量并管理此环境。',
  };

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final env = _find(c, widget.id);
    if (env == null) return _missing(c, '该环境已不存在、已被删除或你已失去访问权限。');
    final n = _name.text.trim();
    final err = _envNameError(n);
    final why = _blocked(c, 'renameEnvironment');
    final readOnly = env.role == AccessRole.readOnly;
    return HPage(
      children: [
        HEnvCard(
          name: env.name,
          count: env.variables.length,
          role: env.role.label,
          roleIcon: _roleIcon(env.role),
          readOnly: readOnly,
        ),
        HNotice(_roleNote(env.role), icon: _roleIcon(env.role)),
        HSection(
          title: '变量',
          trailing: TextButton.icon(
            onPressed: readOnly
                ? null
                : () => c.navigate(
                    VaultPage.variableEditor,
                    environmentId: env.id,
                  ),
            icon: const Icon(Icons.edit_outlined, size: HSize.icon),
            label: const Text('新增或编辑'),
          ),
          children: [
            if (env.variables.isEmpty)
              HEmpty(
                icon: Icons.inbox_outlined,
                title: '暂无变量',
                body: readOnly ? null : '点击“新增或编辑”添加第一个变量。',
              )
            else
              for (final v in env.variables)
                _VarTile(key: ValueKey(v.name), v: v),
          ],
        ),
        if (env.role == AccessRole.admin)
          HSection(
            title: '管理环境',
            form: true,
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
              if (why != null) HHint(why, icon: Icons.lock_outline),
              const Divider(),
              HDangerButton(
                label: '删除环境',
                warning:
                    '将删除“${env.name}”及其 ${env.variables.length} 个变量，且无法撤销。已同步到其他设备的副本不会被远程清除。',
                onConfirm: _canWrite(c, 'deleteEnvironment')
                    ? () => c.deleteEnvironment(env.id)
                    : null,
              ),
            ],
          ),
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: HSize.row),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HSpace.lg,
          HSpace.md,
          HSpace.xs,
          HSpace.md,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: HSpace.xxs,
                children: [
                  Text(widget.v.name, style: hMono(theme.textTheme.titleSmall)),
                  HSecret(widget.v.value, revealed: _revealed),
                ],
              ),
            ),
            IconButton(
              tooltip: _revealed ? '隐藏值' : '显示值',
              onPressed: () => setState(() => _revealed = !_revealed),
              icon: Icon(
                _revealed
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String? _varNameError(String n, {required bool exists}) {
  if (n.isEmpty) return null;
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(n)) {
    return '以字母或下划线开头，仅限字母、数字和下划线，最多 128 个字符';
  }
  if (n.toUpperCase().startsWith('__HARMONIA_')) return '“__HARMONIA_”为保留前缀';
  if (exists) return '该变量已存在，请在上方选择它进行编辑';
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
    return HPage(
      narrow: true,
      children: [
        HSurface(
          child: HRow(
            icon: Icons.layers_outlined,
            tone: env.role == AccessRole.readOnly
                ? HTone.success
                : HTone.accent,
            label: '所属环境',
            title: env.name,
            badge: HPill(env.role.label, icon: _roleIcon(env.role)),
          ),
        ),
        HSection(
          form: true,
          children: [
            DropdownButtonFormField<String?>(
              initialValue: gone ? null : _selected,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '选择变量'),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('新增变量'),
                ),
                for (final name in names)
                  DropdownMenuItem<String?>(
                    value: name,
                    child: Text(name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: c.busy ? null : _pick,
            ),
            if (gone)
              const HNotice('所选变量已不存在，可能已被其他设备删除。', tone: HTone.warning),
            TextField(
              controller: _name,
              readOnly: _selected != null,
              autocorrect: false,
              enableSuggestions: false,
              style: hMono(Theme.of(context).textTheme.bodyLarge),
              decoration: InputDecoration(
                labelText: '名称',
                helperText: _selected != null
                    ? '已有变量的名称不可修改'
                    : '例如 API_BASE_URL',
                errorText: err,
              ),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _value,
              obscureText: !_show,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              decoration: InputDecoration(
                labelText: '值',
                helperText: '保存时校验大小（整个保险库同步数据上限 32 KB）',
                suffixIcon: IconButton(
                  tooltip: _show ? '隐藏值' : '显示值',
                  onPressed: () => setState(() => _show = !_show),
                  icon: Icon(
                    _show
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_unverified)
          const HNotice(
            '无法确认修改是否生效。你的输入已保留，请先刷新确认结果，再决定是否重试。',
            tone: HTone.warning,
          ),
        if (why != null) HHint(why, icon: Icons.lock_outline),
        FilledButton(
          onPressed: why == null && err == null && n.isNotEmpty && !gone
              ? _save
              : null,
          child: const Text('保存'),
        ),
        if (_selected != null && !gone)
          HDangerButton(
            label: '删除变量',
            warning: '变量 $_selected 将从“${env.name}”中移除。',
            onConfirm:
                env.role != AccessRole.readOnly &&
                    _canWrite(c, 'deleteVariable')
                ? _delete
                : null,
          ),
      ],
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) => HPage(
    children: [
      const HPageTitle('设备'),
      HSection(
        title: '已授权设备',
        children: [
          if (c.devices.isEmpty)
            const HEmpty(icon: Icons.devices_outlined, title: '暂无设备记录'),
          for (final d in c.devices)
            HRow(
              icon: _platformIcon(d.platform),
              title: d.name,
              badge: d.current ? const HPill('本机', tone: HTone.accent) : null,
              subtitle: '${d.platform} · 有效期 ${d.expiresLabel}',
              onTap: () => c.navigate(VaultPage.deviceDetail, deviceId: d.id),
            ),
        ],
      ),
      HSection(
        title: '授权请求',
        children: [
          if (!c.authorizationRequestsAvailable)
            Padding(
              padding: const EdgeInsets.all(HSpace.lg),
              child: HHint(
                c.requestCapabilityMessage,
                icon: Icons.construction_outlined,
              ),
            )
          else if (c.pendingAuthorizationRequests.isEmpty)
            const Padding(
              padding: EdgeInsets.all(HSpace.lg),
              child: HHint('没有待处理的请求。', icon: Icons.inbox_outlined),
            )
          else
            for (final r in c.pendingAuthorizationRequests)
              HRow(
                icon: _platformIcon(r.platform),
                tone: HTone.warning,
                title: r.deviceName,
                subtitle: '${r.platform} · ${_time(r.expiresAt)} 前有效',
                onTap: () =>
                    c.navigate(VaultPage.deviceDetail, requestId: r.id),
              ),
        ],
      ),
      HSection(
        children: [
          HRow(
            icon: Icons.how_to_reg_outlined,
            tone: HTone.accent,
            title: '批准新设备',
            subtitle: '输入新设备上显示的配对 ID 和 8 位短码',
            onTap: () => c.navigate(VaultPage.approval),
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
      return HPage(
        narrow: true,
        children: [
          HHeader(
            icon: _platformIcon(r.platform),
            tone: HTone.warning,
            title: r.deviceName,
            body: '请求访问此账号',
          ),
          HSection(
            children: [
              HKeyValue('平台', r.platform),
              HKeyValue('有效至', _time(r.expiresAt)),
              HKeyValue('请求序号', '#${r.sequence}'),
            ],
          ),
          const HHint('不会自动批准。请在两台设备上核对信息后再继续。', icon: Icons.lock_outline),
          FilledButton(
            onPressed: () => c.navigate(VaultPage.approval, requestId: r.id),
            child: const Text('核对并批准'),
          ),
        ],
      );
    }
    final d = _device(c, deviceId);
    if (d == null) return _missing(c, '该设备已不存在或已被撤销。');
    return HPage(
      children: [
        HHeader(
          icon: _platformIcon(d.platform),
          title: d.name,
          body: d.current ? '${d.platform} · 本机' : d.platform,
        ),
        HSection(
          title: '访问',
          children: [
            HKeyValue('访问范围', d.accessSummary),
            HKeyValue('有效期', d.expiresLabel),
          ],
        ),
        HSection(
          title: '调整权限',
          form: true,
          children: [
            _muted(context, '调整环境角色或有效期需要重新配对，并按新的设置重新批准。'),
            OutlinedButton(
              onPressed: () => c.navigate(VaultPage.approval, deviceId: d.id),
              child: const Text('重新配对以调整权限'),
            ),
          ],
        ),
        HSection(
          title: '撤销设备',
          form: true,
          children: [
            _muted(context, '撤销经服务器确认后生效；已同步到该设备的数据无法远程清除。'),
            HDangerButton(
              label: '撤销设备',
              icon: Icons.link_off,
              warning: d.current
                  ? '这是本机，撤销后本机将无法继续同步。'
                  : '将撤销“${d.name}”的访问权限。',
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

  late final SensitiveInputGuard _sensitiveInputs;
  @override
  void initState() {
    super.initState();
    _sensitiveInputs = SensitiveInputGuard(
      [_code],
      onCleared: () {
        if (mounted) {
          setState(() {
            _showCode = false;
            _review = false;
            _checked = false;
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _sensitiveInputs.dispose();
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
      return HPage(
        narrow: true,
        children: [
          const HHeader(title: '核对批准信息', body: '请在两台设备上逐项核对后再批准。'),
          HSection(
            children: [
              HKeyValue('设备', target),
              HKeyValue('配对 ID', _pair.text.trim(), mono: true),
              for (final e in c.environments)
                if (granted[e.id] != null)
                  HKeyValue('环境 · ${e.name}', granted[e.id]!.label),
              HKeyValue('有效期', _life.label),
              CheckboxListTile(
                value: _checked,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('我已在两台设备上核对设备、环境、角色与有效期'),
                onChanged: (v) => setState(() => _checked = v ?? false),
              ),
            ],
          ),
          _hints(const [
            HHint(
              '下一步需要系统验证（设备密码或生物识别）。服务器确认后才算批准，不会自动批准。',
              icon: Icons.fingerprint,
            ),
            HHint('结果不明确时，请先刷新设备列表，不要重复批准。'),
          ]),
          if (why != null) HHint(why, icon: Icons.lock_outline),
          _actions([
            FilledButton(
              onPressed: _checked && why == null ? _approve : null,
              child: const Text('系统验证并批准'),
            ),
            OutlinedButton(
              onPressed: () => setState(() => _review = false),
              child: const Text('返回修改'),
            ),
          ]),
        ],
      );
    }
    return HPage(
      narrow: true,
      children: [
        HNotice(
          req == null && dev == null
              ? '手动配对：配对 ID 只是公开标识，不代表服务器上存在待批准的请求。'
              : '目标：$target',
          icon: Icons.devices_other_outlined,
        ),
        HSection(
          title: '配对信息',
          form: true,
          children: [
            TextField(
              controller: _pair,
              autocorrect: false,
              enableSuggestions: false,
              style: hMono(Theme.of(context).textTheme.bodyLarge),
              decoration: const InputDecoration(
                labelText: '配对 ID（PairID）',
                helperText: '公开标识，显示在新设备上',
              ),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _code,
              obscureText: !_showCode,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              keyboardType: TextInputType.number,
              style: hMono(Theme.of(context).textTheme.bodyLarge),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(8),
              ],
              decoration: InputDecoration(
                labelText: '8 位短码',
                helperText: '显示在新设备上；保留开头的 0，完成后自动清空',
                suffixIcon: IconButton(
                  tooltip: _showCode ? '隐藏短码' : '显示短码',
                  onPressed: () => setState(() => _showCode = !_showCode),
                  icon: Icon(
                    _showCode
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const HHint('短码只在本机参与配对计算，不会发送到服务器。', icon: Icons.lock_outline),
          ],
        ),
        HSection(
          title: '环境权限',
          form: true,
          children: [
            if (c.environments.isEmpty) _muted(context, '没有可授权的环境。'),
            for (final e in c.environments)
              DropdownButtonFormField<AccessRole?>(
                key: ValueKey('role-${e.id}'),
                initialValue: _roles[e.id],
                isExpanded: true,
                decoration: InputDecoration(labelText: e.name),
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
        HSection(
          title: '有效期',
          form: true,
          children: [
            Wrap(
              spacing: HSpace.sm,
              runSpacing: HSpace.sm,
              children: [
                for (final l in _Lifetime.values)
                  ChoiceChip(
                    label: Text(
                      l.label,
                      style: _life == l
                          ? TextStyle(
                              color: Theme.of(context).colorScheme.hCardInk,
                            )
                          : null,
                    ),
                    selected: _life == l,
                    onSelected: (_) => setState(() => _life = l),
                  ),
              ],
            ),
            const HHint('“直到撤销”表示长期有效，直到你在设备详情中撤销。'),
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
  Widget build(BuildContext context) => HPage(
    children: [
      const HPageTitle('设置'),
      HSection(
        children: [
          HRow(
            icon: Icons.shield_outlined,
            tone: HTone.accent,
            title: '账号安全',
            subtitle: '设备信任、App 锁与恢复码',
            onTap: () => c.navigate(VaultPage.accountSecurity),
          ),
        ],
      ),
      HSection(
        title: '服务',
        children: [
          HKeyValue('服务地址', c.previewMode ? '演示模式，未连接服务器' : c.endpoint),
          HKeyValue('连接状态', _phaseLabel(c.phase)),
        ],
      ),
      const HSection(
        title: '关于',
        children: [
          HRow(
            icon: Icons.science_outlined,
            tone: HTone.warning,
            title: '当前为测试版本',
            subtitle: '尚未经过独立安全审计，请勿存放生产环境凭据。',
          ),
        ],
      ),
      HDetails(
        title: '技术信息',
        children: [
          HKeyValue('同步检查点', '#${c.checkpoint}'),
          HKeyValue('连接阶段', c.phase.label),
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
  Widget build(BuildContext context) => HPage(
    children: [
      const HSection(
        title: '身份与设备信任',
        children: [
          HRow(
            icon: Icons.person_outline,
            title: '登录只确认账号身份',
            subtitle: '本机能访问保险库，是因为它已被批准为可信设备。',
          ),
          HRow(
            icon: Icons.devices_outlined,
            title: '管理其他设备',
            subtitle: '撤销设备或调整权限，请前往“设备”。',
          ),
        ],
      ),
      const HSection(
        title: 'App 锁',
        children: [
          SwitchListTile(
            value: false,
            onChanged: null,
            title: Text('打开 App 时验证'),
            subtitle: Text('此版本暂不支持 App 锁。'),
          ),
        ],
      ),
      ...localProtectionSecurityEntries(c),
      HSection(
        title: '恢复',
        children: [
          HRow(
            icon: Icons.health_and_safety_outlined,
            tone: HTone.accent,
            title: '恢复码管理',
            subtitle: c.recoveryStatus,
            onTap: () => c.navigate(VaultPage.recoveryManagement),
          ),
        ],
      ),
    ],
  );
}

class _RecoveryManagement extends StatelessWidget {
  const _RecoveryManagement({required this.c});

  final VaultController c;

  @override
  Widget build(BuildContext context) => HPage(
    children: [
      HSection(
        children: [
          HRow(
            icon: Icons.shield_outlined,
            tone: HTone.accent,
            title: '恢复状态',
            subtitle: c.recoveryStatus,
          ),
        ],
      ),
      HSection(
        title: '轮换恢复码',
        form: true,
        children: [
          _muted(context, '轮换后需要完整重新输入新恢复码。旧恢复码在服务器确认切换后才失效。'),
          const HNotice(
            '此版本暂不支持轮换恢复码，不会生成或显示新的恢复码。',
            icon: Icons.construction_outlined,
          ),
          const FilledButton(onPressed: null, child: Text('开始轮换')),
          OutlinedButton(
            onPressed: c.busy ? null : () => unawaited(c.queryRecoveryStatus()),
            child: const Text('查询恢复状态'),
          ),
          const HHint('结果不明确时，请先查询状态再决定是否重试。'),
        ],
      ),
      const HHint('恢复码不是备份，不保存变量内容。如果同时丢失所有已授权设备和恢复码，旧保险库将无法恢复，只能新建。'),
    ],
  );
}

class _PrivacyShield extends StatelessWidget {
  const _PrivacyShield({required this.c});
  final VaultController c;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(HSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: HSize.formWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(
                child: HIconTile(
                  Icons.lock_outline,
                  tone: HTone.accent,
                  large: true,
                ),
              ),
              const SizedBox(height: HSpace.lg),
              Text(
                c.privacyLocked ? '应用已锁定' : '隐私保护中',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: HSpace.sm),
              Text(
                c.privacyLocked ? '解锁只恢复应用入口，不等于账号登录或设备授权。' : '回到应用后继续。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
              if (c.privacyLocked) ...[
                const SizedBox(height: HSpace.xl),
                FilledButton(
                  onPressed: c.privacyLockAvailable && !c.busy
                      ? () => unawaited(c.unlockPrivacy())
                      : null,
                  child: const Text('验证后解锁'),
                ),
              ],
              if (c.error != null) ...[
                const SizedBox(height: HSpace.md),
                HNotice(c.error!, tone: HTone.danger),
              ],
              if (c.privacyLocked && !c.privacyLockAvailable) ...[
                const SizedBox(height: HSpace.md),
                Text(
                  '此版本暂不支持 App 锁，暂时无法解锁。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
