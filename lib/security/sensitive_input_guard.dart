import 'package:flutter/widgets.dart';

/// 真正后台时清理可控表单缓冲；不改变登录/可信状态或原生恢复owner。
/// 系统认证窗口短暂inactive不清输入、不产生新的认证或权限。
class SensitiveInputGuard extends WidgetsBindingObserver {
  SensitiveInputGuard(this._inputs, {required this._onCleared}) {
    WidgetsBinding.instance.addObserver(this);
  }
  final List<TextEditingController> _inputs;
  final void Function() _onCleared;
  bool _disposed = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed ||
        state != AppLifecycleState.paused &&
            state != AppLifecycleState.detached) {
      return;
    }
    for (final input in _inputs) {
      input.clear();
    }
    _onCleared();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
  }
}
