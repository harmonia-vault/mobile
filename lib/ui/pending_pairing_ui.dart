import 'package:flutter/material.dart';

import '../pairing/pending_pairing_presentation.dart';
import 'design_system.dart';

String _fmt(DateTime d) {
  final l = d.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

bool _expired(PendingPairingHint r) => !r.expiresAt.isAfter(DateTime.now());

String _stateText(PendingPairingHint r) {
  if (r.state == PendingPairingState.approved) return '已批准，等待对方完成';
  return _expired(r) ? '已过期' : '等待审批';
}

/// 设备一级列表内的待审批分组；仅为提示，不证明对方设备可信。
class PendingPairingsSection extends StatefulWidget {
  const PendingPairingsSection({
    super.key,
    required this.controller,
    required this.onReview,
  });
  final PendingPairingActions controller;
  final ValueChanged<PendingPairingHint> onReview;

  @override
  State<PendingPairingsSection> createState() => _PendingPairingsSectionState();
}

class _PendingPairingsSectionState extends State<PendingPairingsSection> {
  bool _pending = false;
  String? _localError;

  Future<void> _refresh() async {
    if (_pending) return;
    setState(() {
      _pending = true;
      _localError = null;
    });
    try {
      await widget.controller.refreshPendingPairings();
    } catch (_) {
      if (mounted) setState(() => _localError = '刷新未完成，请稍后再试。');
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (c is Listenable) {
      return ListenableBuilder(
        listenable: c as Listenable,
        builder: (context, _) => _build(),
      );
    }
    return _build();
  }

  Widget _build() {
    final p = widget.controller.pendingPairings;
    final count = p.pendingCount;
    return HSection(
      title: '待审批请求',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (count > 0) Badge(label: Text('$count')),
          TextButton(
            onPressed: p.available && !p.busy && !_pending ? _refresh : null,
            child: const Text('刷新'),
          ),
        ],
      ),
      footer: '列表仅为提示；批准仍需对方完整8位短码，并明确选择环境、角色与期限。',
      children: [
        if (p.busy || _pending) const LinearProgressIndicator(),
        if (!p.available || p.requests.isEmpty) HHint(p.status),
        if (p.error != null) HNotice(p.error!, tone: HTone.danger),
        if (_localError != null) HNotice(_localError!, tone: HTone.danger),
        if (p.available)
          for (final r in p.requests)
            HRow(
              title: r.initiatorDeviceId,
              label: '发起设备',
              subtitle: '${_stateText(r)} · 有效至 ${_fmt(r.expiresAt)}',
              icon: Icons.phonelink_lock_outlined,
              tone: r.state == PendingPairingState.approved
                  ? HTone.success
                  : (_expired(r) ? HTone.neutral : HTone.warning),
              onTap: () => widget.onReview(r),
            ),
      ],
    );
  }
}

/// 二级核对；继续仅把原请求带入既有短码审批，不是批准。
class PendingPairingDetail extends StatelessWidget {
  const PendingPairingDetail({
    super.key,
    required this.request,
    required this.onContinue,
  });
  final PendingPairingHint request;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final expired = _expired(r);
    final approved = r.state == PendingPairingState.approved;
    return HPage(
      children: [
        const HHeader(
          title: '核对配对请求',
          body: '请与对方设备核对以下信息。此请求本身不证明对方设备可信。',
          icon: Icons.fact_check_outlined,
        ),
        HSection(
          children: [
            HKeyValue('请求ID', r.pairingId, mono: true, selectable: true),
            HKeyValue('发起设备ID', r.initiatorDeviceId, mono: true, selectable: true),
            HKeyValue('状态', _stateText(r)),
            HKeyValue('有效至', _fmt(r.expiresAt)),
          ],
        ),
        HSection(
          children: [
            if (approved)
              const HNotice(
                '此请求已批准，正在等待对方设备完成，无需再次批准。',
                tone: HTone.success,
              )
            else if (expired)
              const HNotice(
                '此请求已过期，不能继续。请让对方设备重新发起。',
                tone: HTone.warning,
              )
            else ...[
              const HNotice(
                '继续后仍需输入对方显示的完整8位短码，并明确选择环境、角色与期限。',
                tone: HTone.accent,
              ),
              FilledButton(
                onPressed: () {
                  if (!_expired(r) && r.state == PendingPairingState.pending) {
                    onContinue();
                  }
                },
                child: const Text('继续审批'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
