import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/ui/harmonia_app.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'navigation_state_test.dart' show FixtureGateway;

// 仅业务/隐私State生命周期回归，不测视觉，也不模拟真实原生授权。
class DeferredWriteGateway extends FixtureGateway {
  final submitted = Completer<void>();
  int writes = 0;
  AccessRole role = AccessRole.admin;
  List<VaultVariable> variables = [];
  List<VaultEnvironment> added = [];
  @override
  Set<String> get capabilities => {
    'restoreSession',
    'setVariable',
    'createEnvironment',
  };
  @override
  Future<void> submit(PreviewMutation mutation) async {
    writes++;
    await submitted.future;
    if (mutation.operation == PreviewOperation.createEnvironment) {
      added = [
        VaultEnvironment(
          id: 'synthetic-new-env',
          name: mutation.name!,
          role: AccessRole.admin,
          variables: const [],
        ),
      ];
    } else {
      variables = [VaultVariable(name: mutation.name!, value: mutation.value!)];
    }
  }

  @override
  Future<VaultSnapshot> pull() async => VaultSnapshot(
    checkpoint: 4 + writes,
    environments: [
      VaultEnvironment(
        id: 'fixture-env',
        name: '合成环境',
        role: role,
        variables: variables,
      ),
      ...added,
    ],
    devices: const [],
  );
}

Finder field(String label, {bool hidden = false}) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
  skipOffstage: !hidden,
);
Future<(VaultController, DeferredWriteGateway, TextEditingController)>
startWrite(WidgetTester t) async {
  t.view.physicalSize = const Size(800, 1200);
  t.view.devicePixelRatio = 1;
  final g = DeferredWriteGateway();
  final c = VaultController(gateway: g);
  await c.unlockSavedDevice();
  c.navigate(VaultPage.environmentDetail, environmentId: 'fixture-env');
  c.navigate(VaultPage.variableEditor, environmentId: 'fixture-env');
  await t.pumpWidget(HarmoniaApp(controller: c));
  c.onLifecycleState(AppLifecycleState.resumed);
  await t.pump();
  await t.enterText(field('名称'), 'SYNTHETIC_FORM');
  await t.enterText(field('值'), 'synthetic-form-value');
  final value = t.widget<TextField>(field('值')).controller!;
  await t.ensureVisible(find.text('保存'));
  await t.tap(find.text('保存'));
  await t.pump();
  expect(g.writes, 1);
  return (c, g, value);
}

Future<void> finish(WidgetTester t, VaultController c) async {
  await t.pumpWidget(const SizedBox.shrink());
  c.dispose();
  t.view.resetPhysicalSize();
  t.view.resetDevicePixelRatio();
  await t.pump();
}

void main() {
  testWidgets('短暂认证inactive隐藏交互/语义/焦点但保留当次State，resumed后成功返回', (t) async {
    final semantics = t.ensureSemantics();
    final (c, g, value) = await startWrite(t);
    c.onLifecycleState(AppLifecycleState.inactive);
    await t.pump();
    expect(field('值', hidden: true), findsOneWidget);
    expect(
      t.widget<TextField>(field('值', hidden: true)).controller,
      same(value),
    );
    expect(value.text, 'synthetic-form-value');
    expect(find.text('保存').hitTestable(), findsNothing);
    expect(field('名称').hitTestable(), findsNothing);
    expect(find.bySemanticsLabel(RegExp('SYNTHETIC_FORM')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('synthetic-form-value')), findsNothing);
    expect(
      FocusManager.instance.primaryFocus?.context?.widget,
      isNot(isA<EditableText>()),
    );
    g.submitted.complete();
    await t.pump(const Duration(milliseconds: 40));
    expect(c.privacyObscured, isTrue);
    c.onLifecycleState(AppLifecycleState.resumed);
    await t.pump(const Duration(milliseconds: 60));
    await t.pump();
    expect(c.error, isNull);
    expect(c.location.page, VaultPage.environmentDetail);
    expect(find.text('SYNTHETIC_FORM'), findsOneWidget);
    expect(g.writes, 1);
    semantics.dispose();
    await finish(t, c);
  });
  testWidgets('取消保留当前草稿且不重发；accepted未知则清旧草稿且不假成功', (t) async {
    for (final unknown in [false, true]) {
      final (c, g, value) = await startWrite(t);
      c.onLifecycleState(AppLifecycleState.inactive);
      await t.pump();
      g.submitted.completeError(
        GatewayFailure('synthetic-fixed-failure', suspendVault: unknown),
      );
      await t.pump(const Duration(milliseconds: 40));
      c.onLifecycleState(AppLifecycleState.resumed);
      await t.pump();
      expect(c.error, isNotNull);
      expect(g.writes, 1);
      if (unknown) {
        expect(value.text, isEmpty);
        expect(c.canEnterVault, isFalse);
        expect(c.environments, isEmpty);
      } else {
        expect(t.widget<TextField>(field('值')).controller, same(value));
        expect(value.text, 'synthetic-form-value');
        expect(c.location.page, VaultPage.variableEditor);
      }
      await finish(t, c);
    }
  });
  testWidgets('真正paused立即dispose草稿；迟到accepted与resumed不复活旧页', (t) async {
    final (c, g, value) = await startWrite(t);
    c.onLifecycleState(AppLifecycleState.inactive);
    await t.pump();
    c.onLifecycleState(AppLifecycleState.paused);
    await t.pump();
    expect(value.text, isEmpty);
    g.submitted.complete();
    await t.pump(const Duration(milliseconds: 60));
    c.onLifecycleState(AppLifecycleState.resumed);
    await t.pump();
    expect(c.canEnterVault, isFalse);
    expect(c.environments, isEmpty);
    expect(g.writes, 1);
    await finish(t, c);
  });
  testWidgets('logout或同账号RO失权都退役旧表单，不保留或重放草稿', (t) async {
    for (final logout in [true, false]) {
      final (c, g, value) = await startWrite(t);
      c.onLifecycleState(AppLifecycleState.inactive);
      await t.pump();
      if (logout) {
        await c.logout();
        await t.pump();
      } else {
        g.role = AccessRole.readOnly;
      }
      g.submitted.complete();
      c.onLifecycleState(AppLifecycleState.resumed);
      await t.pump(const Duration(milliseconds: 60));
      await t.pump();
      expect(value.text, isEmpty);
      expect(g.writes, 1);
      if (logout) {
        expect(c.sessionStage, SessionStage.signedOut);
        expect(c.environments, isEmpty);
      } else {
        expect(c.environments.single.role, AccessRole.readOnly);
        if (field('值').evaluate().isNotEmpty) {
          expect(
            t.widget<TextField>(field('值')).controller,
            isNot(same(value)),
          );
        }
      }
      await finish(t, c);
    }
  });
  testWidgets('新增环境不退役原表单，认证resumed后成功回页并清创建输入', (t) async {
    t.view.physicalSize = const Size(800, 1200);
    t.view.devicePixelRatio = 1;
    final g = DeferredWriteGateway();
    final c = VaultController(gateway: g);
    await c.unlockSavedDevice();
    await t.pumpWidget(HarmoniaApp(controller: c));
    c.onLifecycleState(AppLifecycleState.resumed);
    await t.pump();
    await t.enterText(field('环境名称'), 'SyntheticNew');
    await t.pump();
    final original = t.widget<TextField>(field('环境名称')).controller!;
    final create = find.widgetWithText(FilledButton, '新建环境');
    await t.ensureVisible(create);
    expect(t.widget<FilledButton>(create).onPressed, isNotNull);
    await t.tap(create);
    await t.pump();
    expect(g.writes, 1);
    c.onLifecycleState(AppLifecycleState.inactive);
    await t.pump();
    g.submitted.complete();
    await t.pump(const Duration(milliseconds: 40));
    c.onLifecycleState(AppLifecycleState.resumed);
    await t.pump(const Duration(milliseconds: 60));
    await t.pump();
    expect(c.error, isNull);
    expect(c.location.page, VaultPage.environments);
    expect(c.environments.any((e) => e.name == 'SyntheticNew'), isTrue);
    expect(t.widget<TextField>(field('环境名称')).controller, same(original));
    expect(original.text, isEmpty);
    expect(g.writes, 1);
    await finish(t, c);
  });
}
