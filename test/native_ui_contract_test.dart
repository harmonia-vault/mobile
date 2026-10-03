import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/native/native_ui_contract.dart';
import 'package:harmonia_mobile/vault_controller.dart';

Map<String, Object?> viewFixture() => {
  'checkpoint': 7,
  'deviceId': 'a' * 64,
  'experimental': true,
  'environments': [
    {
      'id': 'env-fixture',
      'name': '合成环境',
      'role': 'Admin',
      'variables': {'DEMO_VALUE': 'synthetic-only'},
    },
  ],
};
Map<String, Object?> trustedFixture() => {
  'trustedDevice': true,
  'accountId': 'account-fixture',
  'accountGeneration': '1',
  'deviceId': 'a' * 64,
  'view': viewFixture(),
};
Map<String, Object?> pendingFixture() => {
  'id': 'original-fixture-id',
  'operation': 'put',
  'environmentId': 'env-fixture',
  'state': 'accepted-not-applied',
  'sequence': 8,
  'applied': false,
};

void main() {
  test('只有当前原生成功信封返回data；旧版本/假experimental/缺ok拒绝', () {
    expect(
      nativeData({
        'version': 1,
        'ok': true,
        'experimental': true,
        'data': 'public-fixture',
      }),
      'public-fixture',
    );
    for (final invalid in [
      {'version': 2, 'ok': true, 'experimental': true},
      {'version': 1, 'ok': true, 'experimental': false},
      {'version': 1, 'experimental': true},
    ]) {
      expect(() => nativeData(invalid), throwsA(isA<GatewayFailure>()));
    }
  });
  test('失败结果即便夹trusted/applied也不解析成功，未知沿原ID', () {
    expect(
      () => nativeData({
        'version': 1,
        'ok': false,
        'experimental': true,
        'code': 'PENDING',
        'retrySameId': true,
        'data': trustedFixture(),
      }, originalId: 'original-fixture-id'),
      throwsA(
        isA<NativeIntentFailure>()
            .having((e) => e.id, '原ID', 'original-fixture-id')
            .having((e) => e.retrySameId, '仅原ID', true),
      ),
    );
    expect(NativeIntentFailure('TRUST_INVALIDATED').trustInvalidated, true);
    expect(NativeIntentFailure('AUTH_CANCELLED').trustInvalidated, false);
  });
  test('真实login DTO永远不升级trusted，禁止data成功布尔替代', () {
    final auth = decodeAccountAuthentication({
      'authenticated': true,
      'trustedDevice': false,
    });
    expect(auth.authenticated, true);
    expect(auth.trustedDevice, false);
    for (final invalid in [
      {'authenticated': true, 'trustedDevice': true},
      {'authenticated': false, 'trustedDevice': false},
      {'authenticated': true},
      true,
    ]) {
      expect(
        () => decodeAccountAuthentication(invalid),
        throwsA(isA<GatewayFailure>()),
      );
    }
  });
  test('registration仅公开代际元数据，不当作已登录或device trust', () {
    final data = NativeRegistration.parse({
      'accountId': 'account-fixture',
      'accountGeneration': '1',
      'verificationRequired': true,
    });
    expect(data.accountGeneration, '1');
    expect(data.verificationRequired, true);
    for (final generation in ['0', '01', '1.0', '-1', '18446744073709551616']) {
      expect(
        () => NativeRegistration.parse({
          'accountId': 'account-fixture',
          'accountGeneration': generation,
          'verificationRequired': false,
        }),
        throwsA(isA<GatewayFailure>()),
      );
    }
  });
  test('可信恢复须native scope+同device view，publickey或单view不足', () {
    final projected = NativeTrustedProjection.parse(trustedFixture());
    expect(projected.session.stage, SessionStage.trusted);
    expect(projected.session.accountId, 'account-fixture');
    expect(projected.view.environments.single.role, AccessRole.admin);
    expect(
      projected.view.environments.single.variables.single.value,
      'synthetic-only',
    );
    for (final invalid in [
      viewFixture(),
      {'trustedDevice': true, 'publicKey': 'synthetic-public-key'},
      {...trustedFixture(), 'accountGeneration': ''},
      {...trustedFixture(), 'trustedDevice': false},
      {...trustedFixture(), 'deviceId': 'b' * 64},
    ]) {
      expect(
        () => NativeTrustedProjection.parse(invalid),
        throwsA(isA<GatewayFailure>()),
      );
    }
  });
  test('Go view role固定RO/RW/Admin，小写wire roles不能冒充view', () {
    for (final entry in {
      'RO': AccessRole.readOnly,
      'RW': AccessRole.readWrite,
      'Admin': AccessRole.admin,
    }.entries) {
      final value = viewFixture();
      ((value['environments'] as List).single as Map)['role'] = entry.key;
      expect(decodeNativeView(value).environments.single.role, entry.value);
    }
    final value = viewFixture();
    ((value['environments'] as List).single as Map)['role'] = 'admin';
    expect(() => decodeNativeView(value), throwsA(isA<GatewayFailure>()));
  });
  test('无效seq、重复环境、保留变量和NUL不会显示native view', () {
    final repeated = viewFixture();
    (repeated['environments'] as List).add(
      (repeated['environments'] as List).single,
    );
    final reserved = viewFixture();
    ((reserved['environments'] as List).single as Map)['variables'] = {
      '__harmonia_PRIVATE': 'synthetic-only',
    };
    final nul = viewFixture();
    ((nul['environments'] as List).single as Map)['variables'] = {
      'DEMO_VALUE': 'synthetic\u0000value',
    };
    for (final invalid in [
      {...viewFixture(), 'checkpoint': -1},
      {...viewFixture(), 'checkpoint': 9007199254740992},
      repeated,
      reserved,
      nul,
    ]) {
      expect(() => decodeNativeView(invalid), throwsA(isA<GatewayFailure>()));
    }
  });
  test('原pending公开有限六字段，accepted不等applied，拒name/value/packet', () {
    final pending = NativePendingOperation.parse(pendingFixture());
    expect(pending.applied, false);
    expect(pending.canRetry, true);
    for (final added in ['name', 'value', 'packet', 'session']) {
      expect(
        () => NativePendingOperation.parse({
          ...pendingFixture(),
          added: 'synthetic-only',
        }),
        throwsA(isA<GatewayFailure>()),
      );
    }
    for (final invalid in [
      {...pendingFixture(), 'applied': true},
      {...pendingFixture(), 'state': 'applied'},
      {...pendingFixture(), 'sequence': 0},
      {...pendingFixture(), 'id': ''},
    ]) {
      expect(
        () => NativePendingOperation.parse(invalid),
        throwsA(isA<GatewayFailure>()),
      );
    }
  });
  test('canceled墓碑与applied不能重试，重复原ID/过多列表拒绝', () {
    expect(
      NativePendingOperation.parse({
        ...pendingFixture(),
        'state': 'canceled',
        'sequence': 0,
      }).canRetry,
      false,
    );
    expect(
      NativePendingOperation.parse({
        ...pendingFixture(),
        'state': 'applied',
        'applied': true,
      }).canRetry,
      false,
    );
    expect(
      () => NativePendingOperation.parseList([
        pendingFixture(),
        pendingFixture(),
      ]),
      throwsA(isA<GatewayFailure>()),
    );
    expect(
      () => NativePendingOperation.parseList(
        List.generate(65, (_) => pendingFixture()),
      ),
      throwsA(isA<GatewayFailure>()),
    );
  });
  test('REJECTED原ID重试是未知写入；明确定Go前系统取消不挂起保险库', () {
    expect(
      NativeIntentFailure(
        'REJECTED',
        retrySameId: true,
        id: 'fixture-original-id',
      ).suspendVault,
      true,
    );
    expect(NativeIntentFailure('REJECTED').suspendVault, false);
    for (final code in [
      'AUTH_CANCELLED',
      'AUTH_FAILED',
      'AUTH_UNAVAILABLE',
      'BUSY',
      'LOCKED',
      'INVALID_COMMAND',
    ]) {
      expect(
        NativeIntentFailure(
          code,
          retrySameId: true,
          id: 'fixture-original-id',
        ).suspendVault,
        false,
      );
    }
  });
}
