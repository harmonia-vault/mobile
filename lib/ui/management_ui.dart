import 'package:flutter/material.dart';

import '../management/management_presentation.dart';
import '../security/sensitive_input_guard.dart';
import 'design_system.dart';

/// 供环境/设备二级页面机械嵌入的入口；打开与否由父界面门槛决定。
class ManagedAccessEntry extends StatelessWidget {
  const ManagedAccessEntry({super.key, required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => HRow(
    title: '设备权限管理',
    subtitle: '调整其他设备在环境中的角色与期限，或撤销整台设备',
    icon: Icons.admin_panel_settings_outlined,
    tone: HTone.accent,
    onTap: onOpen,
  );
}

String _fmt(DateTime d) {
  final l = d.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

enum _Expiry { untilRevoked, until }

class DeviceManagementPanel extends StatefulWidget {
  const DeviceManagementPanel({
    super.key,
    required this.controller,
    required this.environments,
    required this.sensitiveFormScope,
  });
  final ManagementActions controller;
  final List<({String id, String name})> environments;
  final String sensitiveFormScope;

  @override
  State<DeviceManagementPanel> createState() => _DeviceManagementPanelState();
}

class _DeviceManagementPanelState extends State<DeviceManagementPanel> {
  String? _env, _device, _localError;
  ManagedRole? _role;
  _Expiry? _expiry;
  DateTime? _until;
  bool _pending = false;
  int _scopeEpoch = 0, _selectionEpoch = 0;
  late final SensitiveInputGuard _guard;

  @override
  void initState() {
    super.initState();
    _guard = SensitiveInputGuard(
      const [],
      onCleared: () {
        if (mounted) setState(_clearAll);
      },
    );
  }

  @override
  void didUpdateWidget(DeviceManagementPanel old) {
    super.didUpdateWidget(old);
    if (old.sensitiveFormScope != widget.sensitiveFormScope ||
        !identical(old.controller, widget.controller)) {
      _clearAll();
    }
  }

  @override
  void dispose() {
    _guard.dispose();
    super.dispose();
  }

  void _clearAll() {
    _scopeEpoch++;
    _pending = false;
    _env = null;
    _clearDevice();
  }

  void _clearDevice() {
    _selectionEpoch++;
    _device = null;
    _role = null;
    _expiry = null;
    _until = null;
    _localError = null;
  }

  bool _can(ManagementPresentation m, ManagementAction a) =>
      m.allows(a) && !m.busy && !_pending;

  Future<void> _run(Future<void> Function() action) async {
    if (_pending) return;
    final epoch = _scopeEpoch;
    final owner = widget.controller;
    bool current() => mounted && epoch == _scopeEpoch &&
        identical(owner, widget.controller);
    setState(() {
      _pending = true;
      _localError = null;
    });
    try {
      await action();
    } catch (_) {
      if (current()) setState(() => _localError = '操作未完成，请查看上方状态后再试。');
    } finally {
      if (current()) setState(() => _pending = false);
    }
  }

  Future<void> _pickDate() async {
    final epoch = _selectionEpoch;
    final owner = widget.controller;
    final scope = widget.sensitiveFormScope;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 3650)),
      helpText: '选择授权截止日期',
    );
    if (picked == null || !mounted || epoch != _selectionEpoch ||
        !identical(owner, widget.controller) ||
        scope != widget.sensitiveFormScope) {
      return;
    }
    setState(() {
      _until = DateTime(picked.year, picked.month, picked.day, 23, 59);
      _expiry = _Expiry.until;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (c is Listenable) {
      return ListenableBuilder(
        listenable: c as Listenable,
        builder: (context, _) => _build(context),
      );
    }
    return _build(context);
  }

  Widget _build(BuildContext context) {
    final m = widget.controller.management;
    final op = m.operation;
    final env = widget.environments.any((e) => e.id == _env) ? _env : null;
    final listed = env != null && m.environmentId == env;
    final devices = listed
        ? m.devices.where((d) => d.environmentId == env).toList()
        : const <ManagedDeviceAccess>[];
    ManagedDeviceAccess? device;
    for (final d in devices) {
      if (d.deviceId == _device) device = d;
    }
    return HPage(
      children: [
        const HHeader(
          title: '设备权限管理',
          body: '为其他设备调整某个环境的角色与期限，或撤销整台设备。确认变更后还需另行提交。',
          icon: Icons.admin_panel_settings_outlined,
        ),
        _status(m),
        if (op.phase != ManagementPhase.unavailable &&
            op.phase != ManagementPhase.idle)
          _operation(m),
        if (_device != null)
          ..._detail(m, device)
        else
          ..._lists(m, env, listed, devices),
      ],
    );
  }

  Widget _status(ManagementPresentation m) => HSection(
    children: [
      if (m.busy || _pending) const LinearProgressIndicator(),
      HNotice(m.status, icon: Icons.info_outline),
      if (m.error != null) HNotice(m.error!, tone: HTone.danger),
      if (_localError != null) HNotice(_localError!, tone: HTone.danger),
      if (m.allows(ManagementAction.inspect) && !m.operation.unresolved)
        OutlinedButton(
          onPressed: _can(m, ManagementAction.inspect)
              ? () => _run(widget.controller.inspectDeviceManagement)
              : null,
          child: const Text('检查管理状态'),
        ),
    ],
  );

  Widget _operation(ManagementPresentation m) {
    final op = m.operation;
    final revoke = op.kind.toLowerCase().contains('revo');
    final (String text, HTone tone) = switch (op.phase) {
      ManagementPhase.prepared => ('变更已确认，尚未提交。', HTone.warning),
      ManagementPhase.unknown => ('提交结果未知。请查询原变更，或再次提交原变更。', HTone.warning),
      ManagementPhase.acceptedNotApplied => ('服务器已接收，尚未生效。请稍后查询原变更。', HTone.warning),
      ManagementPhase.applied => ('变更已生效。', HTone.success),
      ManagementPhase.cancelled => ('未提交的变更已在本机取消。', HTone.neutral),
      _ => ('', HTone.neutral),
    };
    final envName = widget.environments
            .where((e) => e.id == op.environmentId)
            .map((e) => e.name)
            .firstOrNull ??
        op.environmentId;
    return HSection(
      title: '原变更',
      children: [
        HNotice(text, tone: tone),
        HKeyValue('类型', revoke ? '撤销整台设备' : '调整环境授权'),
        if (envName.isNotEmpty) HKeyValue('环境', envName),
        if (op.subjectDeviceId.isNotEmpty)
          HKeyValue('设备', op.subjectDeviceId, mono: true),
        if (revoke && op.requestExpiresAt != null)
          HKeyValue('本次请求有效至', _fmt(op.requestExpiresAt!)),
        if (!revoke) const HHint('此记录不包含目标角色与期限。'),
        if (op.acceptanceUnknown)
          const HHint('无法确认服务器是否已收到；请只查询或再次提交原变更。'),
        if (op.unresolved)
          Wrap(
            spacing: HSpace.sm,
            runSpacing: HSpace.sm,
            children: [
              FilledButton(
                onPressed: _can(m, ManagementAction.submitOriginal)
                    ? () => _run(widget.controller.submitOriginalManagement)
                    : null,
                child: const Text('提交变更'),
              ),
              OutlinedButton(
                onPressed: _can(m, ManagementAction.inspect)
                    ? () => _run(widget.controller.inspectDeviceManagement)
                    : null,
                child: const Text('查询原变更'),
              ),
              TextButton(
                onPressed: _can(m, ManagementAction.cancelOriginal)
                    ? () => _run(widget.controller.cancelOriginalManagement)
                    : null,
                child: const Text('取消未提交的变更'),
              ),
            ],
          ),
        HDetails(
          title: '技术信息',
          children: [
            HKeyValue('变更ID', op.id, mono: true, selectable: true),
            HKeyValue('序号', '${op.sequence}', mono: true),
            HKeyValue('曾尝试提交', op.attempted ? '是' : '否'),
          ],
        ),
      ],
    );
  }

  List<Widget> _lists(
    ManagementPresentation m,
    String? env,
    bool listed,
    List<ManagedDeviceAccess> devices,
  ) => [
    HSection(
      title: '选择环境',
      children: [
        if (widget.environments.isEmpty) const HHint('当前没有可管理的环境。'),
        for (final e in widget.environments)
          HRow(
            title: e.name,
            icon: Icons.layers_outlined,
            trailing: e.id == env ? const Icon(Icons.check) : null,
            onTap: () {
              setState(() {
                _env = e.id;
                _clearDevice();
              });
              if (_can(m, ManagementAction.loadDevices)) {
                _run(() => widget.controller.loadManagedDevices(e.id));
              }
            },
          ),
      ],
    ),
    if (env != null)
      HSection(
        title: '设备',
        trailing: TextButton(
          onPressed: _can(m, ManagementAction.loadDevices)
              ? () => _run(() => widget.controller.loadManagedDevices(env))
              : null,
          child: const Text('刷新'),
        ),
        children: [
          if (!listed)
            const HHint('尚未加载此环境的设备列表。')
          else if (devices.isEmpty)
            const HHint('此环境没有设备记录。'),
          for (final d in devices)
            HRow(
              title: d.deviceId,
              subtitle: _accessText(d),
              icon: Icons.devices_outlined,
              badge: d.current ? const Badge(label: Text('本机')) : null,
              onTap: () => setState(() {
                _clearDevice();
                _device = d.deviceId;
              }),
            ),
        ],
      ),
  ];

  String _accessText(ManagedDeviceAccess d) {
    if (d.role == ManagedRole.ungranted || d.role == ManagedRole.none) {
      return d.role.label;
    }
    final until = d.expiresAt == null ? '直到撤销' : '至 ${_fmt(d.expiresAt!)}';
    return '${d.role.label} · $until';
  }

  Widget _choice(String title, bool selected, VoidCallback? onTap) => Semantics(
    selected: selected,
    inMutuallyExclusiveGroup: true,
    child: HRow(
      title: title,
      enabled: onTap != null,
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      ),
      onTap: onTap,
    ),
  );

  List<Widget> _detail(ManagementPresentation m, ManagedDeviceAccess? d) {
    final back = TextButton.icon(
      onPressed: () => setState(_clearDevice),
      icon: const Icon(Icons.arrow_back),
      label: const Text('返回设备列表'),
    );
    if (d == null) {
      return [
        HSection(
          children: [
            HNotice(
              '此设备已不在当前列表中，请返回重新选择。',
              tone: HTone.warning,
              actions: [back],
            ),
          ],
        ),
      ];
    }
    final locked = m.operation.unresolved;
    final expiryOk =
        _expiry == _Expiry.untilRevoked ||
        (_expiry == _Expiry.until && _until != null);
    final canGrant =
        _can(m, ManagementAction.prepareGrant) &&
        !locked &&
        _role != null &&
        expiryOk;
    final canRevoke =
        _can(m, ManagementAction.prepareRevocation) && !locked && !d.current;
    return [
      HSection(
        title: '设备详情',
        trailing: back,
        children: [
          HKeyValue('设备ID', d.deviceId, mono: true, selectable: true),
          HKeyValue('当前状态', _accessText(d)),
          if (d.current) const HHint('这是本机。'),
          HDetails(
            title: '技术信息',
            children: [
              HKeyValue('密钥版本', d.keyVersion, mono: true),
              HKeyValue('授权代际', d.grantGeneration, mono: true),
            ],
          ),
        ],
      ),
      HSection(
        title: '新角色',
        footer: '请明确选择；不会预选当前角色。',
        children: [
          for (final r in const [
            ManagedRole.readOnly,
            ManagedRole.readWrite,
            ManagedRole.admin,
            ManagedRole.none,
          ])
            _choice(
              r.label,
              _role == r,
              locked ? null : () => setState(() => _role = r),
            ),
        ],
      ),
      HSection(
        title: '期限',
        footer: '请明确选择期限。',
        children: [
          _choice(
            '直到撤销',
            _expiry == _Expiry.untilRevoked,
            locked ? null : () => setState(() => _expiry = _Expiry.untilRevoked),
          ),
          _choice(
            _until == null ? '到指定日期…' : '到 ${_fmt(_until!)}',
            _expiry == _Expiry.until,
            locked ? null : _pickDate,
          ),
        ],
      ),
      HSection(
        children: [
          if (locked) const HHint('已有未完成的原变更，处理完成前不能确认新的变更。'),
          FilledButton(
            onPressed: canGrant
                ? () {
                    final until = _until;
                    if (_expiry == _Expiry.until &&
                        (until == null || !until.isAfter(DateTime.now()))) {
                      setState(() => _localError = '所选期限已过，请重新选择。');
                      return;
                    }
                    _run(
                      () => widget.controller.prepareManagedDeviceGrant(
                        environmentId: d.environmentId,
                        subjectDeviceId: d.deviceId,
                        role: _role!,
                        expiry: _expiry == _Expiry.untilRevoked
                            ? const ManagementExpiry.untilRevoked()
                            : ManagementExpiry.until(until!),
                      ),
                    );
                  }
                : null,
            child: const Text('确认变更'),
          ),
          const HHint('确认后不会立即生效，需要在“原变更”中另行提交变更。'),
        ],
      ),
      HSection(
        title: '撤销整台设备',
        children: [
          HHint(
            d.current ? '不能在本机上撤销本机。' : '将撤销这台设备的全部访问，不仅是当前环境。',
          ),
          HDangerButton(
            label: '撤销整台其他设备',
            icon: Icons.phonelink_erase_outlined,
            warning: '这台设备将失去全部访问。确认后还需另行提交变更才会执行。',
            onConfirm: canRevoke
                ? () => _run(
                    () => widget.controller.prepareManagedDeviceRevocation(
                      environmentId: d.environmentId,
                      subjectDeviceId: d.deviceId,
                      destructiveConfirmed: true,
                    ),
                  )
                : null,
          ),
        ],
      ),
    ];
  }
}
