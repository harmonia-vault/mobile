import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/security/sensitive_input_guard.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test('平台inactive/resumed不打断系统认证；真实后台清表单并重新遮罩', () {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final password = TextEditingController(text: 'synthetic-password');
    final reentry = TextEditingController(text: 'synthetic-complete-new-code');
    var maskRestored = false;
    final guard = SensitiveInputGuard([
      password,
      reentry,
    ], onCleared: () => maskRestored = true);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(password.text, 'synthetic-password');
    expect(reentry.text, 'synthetic-complete-new-code');
    expect(maskRestored, false);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(password.text, isEmpty);
    expect(reentry.text, isEmpty);
    expect(maskRestored, true);
    guard.dispose();
    password.dispose();
    reentry.dispose();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  test('页面销毁后解绑平台观察，旧后台事件不能调用已销毁的输入', () {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final proof = TextEditingController(text: 'synthetic-proof');
    var cleared = 0;
    final guard = SensitiveInputGuard([proof], onCleared: () => cleared++);
    guard.dispose();
    proof.dispose();
    expect(
      () => binding.handleAppLifecycleStateChanged(AppLifecycleState.paused),
      returnsNormally,
    );
    expect(cleared, 0);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
