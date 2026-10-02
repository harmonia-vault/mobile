import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../vault_controller.dart';

const _seed = Color(0xFF00695C);
const _defaultEndpoint = 'https://vault.example.invalid';

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

class HarmoniaApp extends StatelessWidget {
  const HarmoniaApp({super.key, required this.controller});

  final VaultController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
      home: _Shell(controller: controller),
    );
  }
}

/// Real edits need the controller online; synthetic preview edits stay in local memory.
bool _canWrite(VaultController c) =>
    !c.busy && (c.previewMode || c.phase == ConnectionPhase.online);

VaultEnvironment? _find(List<VaultEnvironment> list, String id) {
  for (final e in list) {
    if (e.id == id) return e;
  }
  return null;
}

String _phaseHint(ConnectionPhase phase) => switch (phase) {
  ConnectionPhase.preview => '合成预览：数据只在本地内存中，不代表真实保险库。',
  ConnectionPhase.blocked => '已失败关闭：加密、配对或本机密钥保护尚不可用。',
  ConnectionPhase.syncing => '正在同步，结果以控制器确认为准。',
  ConnectionPhase.online => '已连接。修改需服务器确认后才生效。',
  ConnectionPhase.offline => '离线：真实修改已禁用，请检查端点后刷新。',
};

IconData _phaseIcon(ConnectionPhase phase) => switch (phase) {
  ConnectionPhase.preview => Icons.visibility_outlined,
  ConnectionPhase.blocked => Icons.block,
  ConnectionPhase.syncing => Icons.sync,
  ConnectionPhase.online => Icons.cloud_done_outlined,
  ConnectionPhase.offline => Icons.cloud_off_outlined,
};

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async {
  final s = Theme.of(context).colorScheme;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: s.error),
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: s.error,
            foregroundColor: s.onError,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

class _Shell extends StatefulWidget {
  const _Shell({required this.controller});

  final VaultController controller;

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int _index = 0;

  static const _dests = [
    (Icons.layers_outlined, Icons.layers, '环境'),
    (Icons.devices_outlined, Icons.devices, '设备'),
    (Icons.health_and_safety_outlined, Icons.health_and_safety, '恢复'),
    (Icons.settings_outlined, Icons.settings, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final wide = MediaQuery.sizeOf(context).width >= 700;
        final page = switch (_index) {
          0 => _EnvironmentsPage(c: c),
          1 => _DevicesPage(c: c),
          2 => _RecoveryPage(c: c),
          _ => _SettingsPage(c: c),
        };
        final body = _Frame(c: c, child: page);
        return Scaffold(
          appBar: AppBar(
            title: Text('和弦 · ${_dests[_index].$3}'),
            actions: [
              IconButton(
                tooltip: '刷新',
                onPressed: c.busy ? null : () => unawaited(c.reload()),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            bottom: wide,
            child: wide
                ? Row(
                    children: [
                      NavigationRail(
                        selectedIndex: _index,
                        labelType: NavigationRailLabelType.all,
                        onDestinationSelected: (i) =>
                            setState(() => _index = i),
                        destinations: [
                          for (final d in _dests)
                            NavigationRailDestination(
                              icon: Icon(d.$1),
                              selectedIcon: Icon(d.$2),
                              label: Text(d.$3),
                            ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: body),
                    ],
                  )
                : body,
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  destinations: [
                    for (final d in _dests)
                      NavigationDestination(
                        icon: Icon(d.$1),
                        selectedIcon: Icon(d.$2),
                        label: d.$3,
                      ),
                  ],
                ),
        );
      },
    );
  }
}

/// Shared progress, status and error chrome above every page.
class _Frame extends StatelessWidget {
  const _Frame({required this.c, required this.child});

  final VaultController c;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (c.busy)
          const LinearProgressIndicator()
        else
          const SizedBox(height: 4),
        _StatusStrip(c: c),
        if (c.error != null) _ErrorBanner(c: c),
        Expanded(child: child),
      ],
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
                const _Tag(Icons.science_outlined, '实验性'),
                if (c.previewMode)
                  const _Tag(Icons.visibility_outlined, '合成预览'),
                _Tag(_phaseIcon(c.phase), '状态：${c.phase.label}'),
              ],
            ),
            const SizedBox(height: 4),
            Text(_phaseHint(c.phase), style: theme.textTheme.bodySmall),
            if (c.previewMode)
              Text('预览变更，不会上传。', style: theme.textTheme.bodySmall),
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
                      '操作未生效。请检查端点与网络后重试；预览数据不受影响。',
                      style: text.bodySmall?.copyWith(
                        color: s.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: c.busy ? null : () => unawaited(c.reload()),
                child: const Text('重试'),
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

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, this.initial = ''});

  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _name.text.trim();
    if (v.isNotEmpty) Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _name,
      autofocus: true,
      decoration: const InputDecoration(labelText: '环境名称', hintText: '例如 开发'),
      textInputAction: TextInputAction.done,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _name.text.trim().isEmpty ? null : _submit,
        child: const Text('确定'),
      ),
    ],
  );
}

class _VariableDialog extends StatefulWidget {
  const _VariableDialog({required this.preview, this.name, this.value});

  final bool preview;
  final String? name;
  final String? value;

  @override
  State<_VariableDialog> createState() => _VariableDialogState();
}

class _VariableDialogState extends State<_VariableDialog> {
  late final _name = TextEditingController(text: widget.name ?? '');
  late final _value = TextEditingController(text: widget.value ?? '');
  bool _show = false;

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.name != null;
    return AlertDialog(
      title: Text(editing ? '编辑变量' : '添加变量'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              readOnly: editing,
              autofocus: !editing,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: '名称',
                helperText: editing ? '名称不可修改' : '例如 API_BASE_URL',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _value,
              obscureText: !_show,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: '值',
                suffixIcon: IconButton(
                  tooltip: _show ? '隐藏值' : '显示值',
                  onPressed: () => setState(() => _show = !_show),
                  icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                ),
              ),
            ),
            if (widget.preview) const _Note('预览变更，不会上传。'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, (_name.text.trim(), _value.text)),
          child: const Text('提交'),
        ),
      ],
    );
  }
}

class _EnvironmentsPage extends StatelessWidget {
  const _EnvironmentsPage({required this.c});

  final VaultController c;

  Future<void> _create(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NameDialog(title: '新建环境'),
    );
    if (name != null) await c.createEnvironment(name);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final canWrite = _canWrite(c);
    return _Page(
      children: [
        Text('同步状态：${c.phase.label}', style: text.headlineSmall),
        Text(
          '检查点 #${c.checkpoint}',
          style: text.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        if (c.previewMode)
          const _Note(
            '当前为合成预览：以下环境与变量是本地内存中的示例，变更不会上传或写入真实保险库。',
            icon: Icons.visibility_outlined,
          ),
        Row(
          children: [
            Expanded(child: Text('环境', style: text.titleMedium)),
            FilledButton.tonalIcon(
              onPressed: canWrite ? () => _create(context) : null,
              icon: const Icon(Icons.add),
              label: const Text('新建环境'),
            ),
          ],
        ),
        if (!canWrite && !c.busy)
          const _Note('离线或已失败关闭时无法修改。', icon: Icons.lock_outline),
        const SizedBox(height: 8),
        if (c.environments.isEmpty)
          const _Section(
            title: '还没有环境',
            children: [
              Text('环境是一组变量（例如“开发”“生产”）。新建环境后再添加变量；每台设备的角色决定只读、读写或管理。'),
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
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _EnvironmentDetail(c: c, id: e.id),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}

class _EnvironmentDetail extends StatelessWidget {
  const _EnvironmentDetail({required this.c, required this.id});

  final VaultController c;
  final String id;

  static String _roleNote(AccessRole role) => switch (role) {
    AccessRole.readOnly => '只读权限：可查看（值默认隐藏），不能添加、编辑或删除。',
    AccessRole.readWrite => '读写权限：可编辑变量；重命名和删除环境需要管理权限。',
    AccessRole.admin => '管理权限：可编辑变量并管理此环境。',
  };

  Future<void> _rename(BuildContext context, VaultEnvironment env) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(title: '重命名环境', initial: env.name),
    );
    if (name != null && name != env.name) {
      await c.renameEnvironment(env.id, name);
    }
  }

  Future<void> _delete(BuildContext context, VaultEnvironment env) async {
    final ok = await _confirm(
      context,
      title: '删除环境“${env.name}”？',
      body: '将删除此环境及其 ${env.variables.length} 个变量，无法撤销。已同步到其他设备的副本不会被远程清除。',
      action: '删除环境',
    );
    if (!ok) return;
    await c.deleteEnvironment(env.id);
    if (!context.mounted) return;
    if (_find(c.environments, env.id) == null) Navigator.of(context).pop();
  }

  Future<void> _add(BuildContext context, VaultEnvironment env) async {
    final r = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _VariableDialog(preview: c.previewMode),
    );
    if (r != null) await c.setVariable(env.id, r.$1, r.$2);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final found = _find(c.environments, id);
        if (found == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('环境')),
            body: const _Page(children: [_Note('该环境已不存在或已被删除。')]),
          );
        }
        final env = found;
        final write = _canWrite(c);
        final canEdit = write && env.role != AccessRole.readOnly;
        final canManage = write && env.role == AccessRole.admin;
        return Scaffold(
          appBar: AppBar(
            title: Text(env.name),
            actions: [
              IconButton(
                tooltip: '重命名',
                onPressed: canManage ? () => _rename(context, env) : null,
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: '删除环境',
                onPressed: canManage ? () => _delete(context, env) : null,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          floatingActionButton: canEdit
              ? FloatingActionButton.extended(
                  onPressed: () => _add(context, env),
                  icon: const Icon(Icons.add),
                  label: const Text('添加变量'),
                )
              : null,
          body: SafeArea(
            top: false,
            child: _Frame(
              c: c,
              child: _Page(
                children: [
                  _Note(
                    _roleNote(env.role),
                    icon: env.role == AccessRole.readOnly
                        ? Icons.lock_outline
                        : Icons.badge_outlined,
                  ),
                  if (!write && !c.busy)
                    const _Note('当前无法修改：需要连接或合成预览模式。', icon: Icons.cloud_off),
                  const SizedBox(height: 8),
                  if (env.variables.isEmpty)
                    const _Note('暂无变量。', icon: Icons.inbox_outlined)
                  else
                    for (final v in env.variables)
                      _VariableTile(
                        key: ValueKey(v.name),
                        c: c,
                        env: env,
                        variable: v,
                        canEdit: canEdit,
                      ),
                  const SizedBox(height: 88),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _VariableTile extends StatefulWidget {
  const _VariableTile({
    super.key,
    required this.c,
    required this.env,
    required this.variable,
    required this.canEdit,
  });

  final VaultController c;
  final VaultEnvironment env;
  final VaultVariable variable;
  final bool canEdit;

  @override
  State<_VariableTile> createState() => _VariableTileState();
}

class _VariableTileState extends State<_VariableTile> {
  bool _revealed = false;

  Future<void> _edit() async {
    final v = widget.variable;
    final r = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _VariableDialog(
        preview: widget.c.previewMode,
        name: v.name,
        value: v.value,
      ),
    );
    if (r != null) await widget.c.setVariable(widget.env.id, r.$1, r.$2);
  }

  Future<void> _delete() async {
    final ok = await _confirm(
      context,
      title: '删除变量 ${widget.variable.name}？',
      body: '此变量将从“${widget.env.name}”中移除。',
      action: '删除',
    );
    if (ok) await widget.c.deleteVariable(widget.env.id, widget.variable.name);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.variable;
    return Card(
      child: ListTile(
        title: Text(v.name),
        subtitle: Text(
          _revealed ? v.value : '••••••••',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: _revealed ? '隐藏值' : '显示值',
              onPressed: () => setState(() => _revealed = !_revealed),
              icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility),
            ),
            IconButton(
              tooltip: '编辑',
              onPressed: widget.canEdit ? _edit : null,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: '删除',
              onPressed: widget.canEdit ? _delete : null,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Lifetime { hour, day, untilRevoked }

class _DevicesPage extends StatefulWidget {
  const _DevicesPage({required this.c});

  final VaultController c;

  @override
  State<_DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<_DevicesPage> {
  final _code = TextEditingController();
  final Map<String, AccessRole?> _roles = {};
  _Lifetime _life = _Lifetime.hour;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Duration? get _duration => switch (_life) {
    _Lifetime.hour => const Duration(hours: 1),
    _Lifetime.day => const Duration(days: 1),
    _Lifetime.untilRevoked => null,
  };

  Map<String, AccessRole> get _granted => {
    for (final e in widget.c.environments)
      if (_roles[e.id] != null) e.id: _roles[e.id]!,
  };

  Future<void> _approve() async {
    final draft = ApprovalDraft(
      code: _code.text.trim(),
      roles: _granted,
      lifetime: _duration,
    );
    setState(_code.clear); // one-time code is not kept after an attempt
    await widget.c.approveDevice(draft);
  }

  Future<void> _revoke(VaultDevice d) async {
    final ok = await _confirm(
      context,
      title: '撤销“${d.name}”？',
      body:
          '${d.current ? '这是本机，撤销后本机将无法继续同步。\n' : ''}'
          '撤销需服务器确认后才生效；已同步到该设备的数据无法远程清除。',
      action: '撤销',
    );
    if (ok) await widget.c.revokeDevice(d.id);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final canSubmit =
        !c.busy && _code.text.trim().isNotEmpty && _granted.isNotEmpty;
    return _Page(
      children: [
        _Section(
          title: '已授权设备',
          children: [
            if (c.previewMode)
              const _Note('以下设备为合成示例。', icon: Icons.visibility_outlined),
            if (c.devices.isEmpty) const Text('暂无设备记录。'),
            for (final d in c.devices)
              ListTile(
                contentPadding: EdgeInsets.zero,
                isThreeLine: true,
                leading: Icon(
                  d.platform.toLowerCase().contains(RegExp('android|ios'))
                      ? Icons.smartphone
                      : Icons.laptop,
                ),
                title: Text(d.current ? '${d.name}（本机）' : d.name),
                subtitle: Text(
                  '${d.platform} · ${d.accessSummary}\n有效期：${d.expiresLabel}',
                ),
                trailing: TextButton(
                  onPressed: c.busy ? null : () => _revoke(d),
                  child: const Text('撤销'),
                ),
              ),
          ],
        ),
        _Section(
          title: '批准新设备',
          children: [
            const _Note(
              '配对需在两台设备之间本地完成 SPAKE2 交换。短码只在本机参与配对计算，不会发送到服务器或普通云端。'
              '本机配对能力不可用时，请求会失败关闭并显示原因。',
              icon: Icons.lock_outline,
            ),
            TextField(
              controller: _code,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              maxLength: 12,
              decoration: const InputDecoration(
                labelText: '新设备显示的短码',
                helperText: '仅用于本地配对，提交后即清空',
              ),
              onChanged: (_) => setState(() {}),
            ),
            Text('各环境权限', style: Theme.of(context).textTheme.titleSmall),
            if (c.environments.isEmpty) const Text('没有可授权的环境。'),
            for (final e in c.environments)
              Row(
                children: [
                  Expanded(child: Text(e.name)),
                  DropdownButton<AccessRole?>(
                    value: _roles[e.id],
                    hint: const Text('无访问'),
                    onChanged: c.busy
                        ? null
                        : (v) => setState(() => _roles[e.id] = v),
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
              segments: const [
                ButtonSegment(value: _Lifetime.hour, label: Text('1 小时')),
                ButtonSegment(value: _Lifetime.day, label: Text('1 天')),
                ButtonSegment(
                  value: _Lifetime.untilRevoked,
                  label: Text('直到撤销'),
                ),
              ],
              selected: {_life},
              onSelectionChanged: c.busy
                  ? null
                  : (s) => setState(() => _life = s.first),
            ),
            const Text('“直到撤销”为永久有效，直到在本页撤销。'),
            FilledButton.icon(
              onPressed: canSubmit ? _approve : null,
              icon: const Icon(Icons.how_to_reg_outlined),
              label: const Text('请求批准'),
            ),
            const _Note('结果以控制器返回为准；提交不代表已批准，失败会显示在顶部。'),
          ],
        ),
      ],
    );
  }
}

class _RecoveryPage extends StatefulWidget {
  const _RecoveryPage({required this.c});

  final VaultController c;

  @override
  State<_RecoveryPage> createState() => _RecoveryPageState();
}

class _RecoveryPageState extends State<_RecoveryPage> {
  final _newCode = TextEditingController();
  bool _show = false;
  bool _needsQuery = false;

  @override
  void dispose() {
    _newCode.dispose();
    super.dispose();
  }

  Future<void> _rotate() async {
    final value = _newCode.text;
    setState(() {
      _needsQuery = true;
      _newCode.clear();
    });
    await widget.c.rotateRecovery(value);
  }

  Future<void> _query() async {
    await widget.c.queryRecoveryStatus();
    if (mounted && widget.c.error == null) setState(() => _needsQuery = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final s = Theme.of(context).colorScheme;
    return _Page(
      children: [
        Card(
          color: c.restrictedRecovery
              ? s.tertiaryContainer
              : s.secondaryContainer,
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: Icon(
              c.restrictedRecovery
                  ? Icons.gpp_maybe_outlined
                  : Icons.shield_outlined,
            ),
            title: Text(c.restrictedRecovery ? '受限恢复会话：仅允许恢复相关操作' : '恢复状态'),
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
          title: '开始恢复',
          children: [
            const Text('在本设备发起恢复请求。流程由安全适配器执行；不可用时会失败关闭并显示原因。'),
            FilledButton.tonal(
              onPressed: c.busy ? null : () => unawaited(c.beginRecovery()),
              child: const Text('请求开始恢复流程'),
            ),
          ],
        ),
        _Section(
          title: '轮换恢复码',
          children: [
            const Text('新恢复码由安全适配器生成并单独显示。请在下方完整重新输入新恢复码；本页不收集旧恢复码。'),
            TextField(
              controller: _newCode,
              obscureText: !_show,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              decoration: InputDecoration(
                labelText: '完整输入新恢复码',
                suffixIcon: IconButton(
                  tooltip: _show ? '隐藏' : '显示',
                  onPressed: () => setState(() => _show = !_show),
                  icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const _Note('重新输入只校验抄写一致，不能证明你已妥善备份。'),
            const _Note('旧恢复码只在服务器确认原子切换完成后才失效。结果不确定时，请先查询再重试。'),
            if (_needsQuery)
              const _Note(
                '上次轮换已提交，需先查询结果才能再次提交。',
                icon: Icons.warning_amber_rounded,
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: !c.busy && !_needsQuery && _newCode.text.isNotEmpty
                      ? _rotate
                      : null,
                  child: const Text('提交轮换'),
                ),
                OutlinedButton(
                  onPressed: c.busy ? null : _query,
                  child: const Text('查询轮换结果'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({required this.c});

  final VaultController c;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late final _endpoint = TextEditingController(
    text: widget.c.endpoint.isEmpty ? _defaultEndpoint : widget.c.endpoint,
  );
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _showPassword = false;

  @override
  void dispose() {
    _endpoint.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final email = _email.text.trim();
    final password = _password.text;
    setState(_password.clear); // password is never retained in UI state
    await widget.c.signIn(email, password);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return _Page(
      children: [
        _Section(
          title: '服务器端点',
          children: [
            const Text('仅支持自托管 HTTPS 端点。由控制器校验后应用；校验失败会在顶部显示原因，当前端点保持不变。'),
            TextField(
              controller: _endpoint,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: '端点 URL',
                hintText: _defaultEndpoint,
                helperText: '当前：${c.endpoint}',
              ),
              onChanged: (_) => setState(() {}),
            ),
            FilledButton(
              onPressed: c.busy || _endpoint.text.trim().isEmpty
                  ? null
                  : () => unawaited(c.setEndpoint(_endpoint.text.trim())),
              child: const Text('应用端点'),
            ),
          ],
        ),
        _Section(
          title: '账户登录',
          children: [
            const _Note(
              '登录只证明账户身份，不会让本设备成为受信任设备；设备信任需在“设备”页另行批准。',
              icon: Icons.person_outline,
            ),
            const _Note('登录凭据由密码派生，按设计与保险库加密相互独立。实现后凭据只会通过 HTTPS 发送。'),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '邮箱',
                hintText: 'name@example.invalid',
              ),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _password,
              obscureText: !_showPassword,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: '密码',
                suffixIcon: IconButton(
                  tooltip: _showPassword ? '隐藏密码' : '显示密码',
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                  icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            FilledButton(
              onPressed:
                  c.busy || _email.text.trim().isEmpty || _password.text.isEmpty
                  ? null
                  : _signIn,
              child: const Text('登录'),
            ),
          ],
        ),
        const _Section(
          title: '实验性实现边界',
          children: [
            _Note(
              '加密、设备配对（SPAKE2）与恢复由独立安全适配器提供，默认失败关闭。',
              icon: Icons.science_outlined,
            ),
            _Note('本机设备密码 / 强生物识别密钥保护尚待接入。', icon: Icons.fingerprint),
            _Note('未经安全审计，请勿用于生产凭据。', icon: Icons.warning_amber_rounded),
          ],
        ),
      ],
    );
  }
}
