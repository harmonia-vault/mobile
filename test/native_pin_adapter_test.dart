import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/native/native_pin_adapter.dart';
import 'package:harmonia_mobile/native/native_ui_contract.dart';
import 'package:harmonia_mobile/native/native_vault_gateway.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'native_gateway_mapping_test.dart' show PortFixture, connected;

class PINPortFixture extends PortFixture implements NativeLocalProtectionPort {
  @override
  Future<LocalProtectionStatus> localProtectionInfo(String endpoint) =>
      NativePINAdapter(endpoint).information();
}

class LateFaultPortFixture extends PortFixture {
  String fault = 'LOCAL_PROTECTION_PERSISTENCE';
  int acceptedWrites = 0;
  @override
  Future<Map<String, Object?>> execute(
    String endpoint,
    String operation,
    Map<String, String> fields,
  ) async {
    final result = await super.execute(endpoint, operation, fields);
    if (operation == 'setVariable') {
      acceptedWrites++;
      throw PlatformException(code: fault);
    }
    return result;
  }
}

// 仅Dart意图/缓冲/资格门槛测试，不证明真实KDF/Keystore/系统能力/云端信任。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const endpoint = 'https://pin.synthetic.invalid';
  const channel = MethodChannel('org.harmoniavault/native/v1');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  Map<String, Object?> status({
    String mode = 'none',
    bool exists = false,
    bool ready = false,
    bool upgrade = false,
  }) => {
    'version': 1,
    'profile': 'harmonia/local-protection/v1',
    'mode': mode,
    'systemCapability': 'NO_SYSTEM_AUTH',
    'deviceExists': exists,
    'pinSetupAvailable': mode == 'none' && !exists && !upgrade,
    'upgradeRequired': upgrade,
    'pinWorkflowReady': ready,
    'delaySeconds': 0,
    'pinForgetAvailable': exists && (mode == 'pin' || mode == 'blocked'),
  };
  Future<NativeVaultGateway> gateway(
    PINPortFixture port, {
    Set<String>? pinEvidence,
  }) async {
    final value = NativeVaultGateway(
      experimentalOptIn: true,
      port: port,
      verifiedPINOperations: pinEvidence,
      inspector: (_) async => const InstanceDescriptor(
        initialRegistrationAvailable: false,
        allowRegistration: true,
        emailVerificationRequired: false,
      ),
    );
    await value.initialize('');
    await value.inspectInstance(endpoint);
    value.bindVerifiedServer(endpoint);
    return value;
  }

  test('strict status rejects downgrade or unknown metadata', () {
    expect(LocalProtectionStatus.parse(status()).pinSetupAvailable, true);
    expect(
      () => LocalProtectionStatus.parse({
        ...status(mode: 'system', exists: true),
        'pinForgetAvailable': true,
      }),
      throwsFormatException,
    );
    expect(
      LocalProtectionStatus.parse(status(mode: 'blocked', exists: true))
          .pinForgetAvailable,
      true,
    );
    expect(
      () => LocalProtectionStatus.parse({...status(), 'deviceExists': true}),
      throwsFormatException,
    );
    expect(
      () => LocalProtectionStatus.parse({...status(), 'callerTrusted': true}),
      throwsFormatException,
    );
    expect(
      () => LocalProtectionStatus.parse({...status(), 'delaySeconds': 601}),
      throwsFormatException,
    );
  });

  test(
    'setup owns transferred buffers and clears after success or native failure',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'setupLocalPIN');
        calls++;
        expect(
          (call.arguments as Map)['pin'],
          orderedEquals(ascii.encode('123456')),
        );
        if (calls == 2) {
          throw PlatformException(code: 'LOCAL_PROTECTION_PERSISTENCE');
        }
        return jsonEncode({
          'version': 1,
          'deviceId': 'a' * 64,
          'trusted': false,
        });
      });
      final first = LocalPINInput(
        Uint8List.fromList(ascii.encode('123456')),
        reentry: Uint8List.fromList(ascii.encode('123456')),
      );
      await const NativePINAdapter(endpoint).setup(first);
      expect(first.pin, everyElement(0));
      expect(first.reentry, everyElement(0));
      final second = LocalPINInput(
        Uint8List.fromList(ascii.encode('123456')),
        reentry: Uint8List.fromList(ascii.encode('123456')),
      );
      await expectLater(
        const NativePINAdapter(endpoint).setup(second),
        throwsA(isA<PlatformException>()),
      );
      expect(second.pin, everyElement(0));
      expect(second.reentry, everyElement(0));
    },
  );

  test('PIN candidate metadata cannot enable cloud operations without independent evidence', () async {
    final port = PINPortFixture()..systemStrong = false;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => status(mode: 'pin', exists: true, ready: true),
    );
    final value = await gateway(port, pinEvidence: const {});
    await value.refreshLocalProtection();
    expect(value.localProtectionStatus!.mode, LocalProtectionMode.pin);
    expect(value.capabilities, isEmpty);
    await expectLater(
      value.registerAccount('synthetic@example.invalid', 'synthetic-password'),
      throwsA(isA<GatewayFailure>()),
    );
    expect(port.calls, isEmpty);
    expect(port.createCalls, 0);
  });

  test(
    'canceled PIN is never a system-provider fallback or a business request',
    () async {
      final port = PINPortFixture()..systemStrong = false;
      var posts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'localProtectionInfo') {
          return status(mode: 'pin', exists: true, ready: true);
        }
        posts++;
        return null;
      });
      final value = await gateway(port, pinEvidence: {'register'});
      value.bindLocalPINCallbacks(
        prompt: (_) async => null,
        confirmForget: () async => false,
      );
      await value.refreshLocalProtection();
      await expectLater(
        value.registerAccount(
          'synthetic@example.invalid',
          'synthetic-password',
        ),
        throwsA(
          isA<NativeIntentFailure>().having(
            (e) => e.code,
            'code',
            'PIN_CANCELLED',
          ),
        ),
      );
      expect(posts, 0);
      expect(port.calls, isEmpty);
      expect(port.createCalls, 0);
    },
  );

  test(
    'forget reports failure until exact native cleanup acknowledgement',
    () async {
      var deleted = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'localProtectionInfo') {
          return deleted ? status() : status(mode: 'pin', exists: true);
        }
        if (!deleted) {
          deleted = true;
          throw PlatformException(code: 'LOCAL_PROTECTION_PERSISTENCE');
        }
        return {'version': 1, 'cleared': true, 'trustedDevice': false};
      });
      final value = await gateway(PINPortFixture()..systemStrong = false);
      value.bindLocalPINCallbacks(
        prompt: (_) async => null,
        confirmForget: () async => true,
      );
      await value.refreshLocalProtection();
      await expectLater(
        value.forgetLocalPIN(),
        throwsA(isA<NativeIntentFailure>()),
      );
      expect(value.localProtectionStatus!.deviceExists, true);
      expect(value.capabilities, isEmpty);
      await value.forgetLocalPIN();
      expect(value.localProtectionStatus!.deviceExists, false);
      expect(value.localProtectionStatus!.pinSetupAvailable, true);
    },
  );
  test('late native store or close failure keeps original write unknown and blocks a fresh request', () async {
    for (final fault in [
      'LOCAL_PROTECTION_PERSISTENCE',
      'LOCAL_PROTECTION_STATE',
      'PIN_BLOCKED',
    ]) {
      final port = LateFaultPortFixture()..fault = fault;
      final value = await connected(port);
      await value.restoreSession();
      NativeIntentFailure? result;
      try {
        await value.submit(
          const PreviewMutation(
            PreviewOperation.setVariable,
            environmentId: 'env-fixture',
            name: 'SYNTHETIC_NAME',
            value: 'synthetic-value-only',
          ),
        );
      } on NativeIntentFailure catch (failure) {
        result = failure;
      }
      expect(result, isNotNull);
      expect(result!.id, isNotNull);
      expect(result.retrySameId, true);
      expect(result.suspendVault, true);
      final original = port.calls
          .where((call) => call.$1 == 'setVariable')
          .single
          .$2['id'];
      expect(result.id, original);
      expect(port.acceptedWrites, 1);
      await expectLater(
        value.submit(
          const PreviewMutation(
            PreviewOperation.setVariable,
            environmentId: 'env-fixture',
            name: 'SYNTHETIC_NAME',
            value: 'replacement-intent-forbidden',
          ),
        ),
        throwsA(isA<GatewayFailure>()),
      );
      expect(
        port.calls.where((call) => call.$1 == 'setVariable'),
        hasLength(1),
      );
    }
  });

  for (final unavailable in ['NO_SYSTEM_AUTH', 'BLOCKED']) {
    test('system $unavailable retires plaintext until authenticated restore', () async {
      final port = PINPortFixture()..deviceExists = true;
      var systemCapability = 'SYSTEM_READY';
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'localProtectionInfo');
        return {
          ...status(mode: 'system', exists: true),
          'systemCapability': systemCapability,
        };
      });
      final value = await gateway(port);
      final controller = VaultController(gateway: value);
      await controller.initialize();
      await controller.connectServer(endpoint);
      await controller.unlockSavedDevice();
      expect(controller.canEnterVault, isTrue);
      expect(controller.environments, isNotEmpty);
      await controller.refreshLocalProtection();
      expect(controller.canEnterVault, isTrue);
      final callsBefore = port.calls.length;

      systemCapability = unavailable;
      await controller.refreshLocalProtection();
      // Native mode stays system: losing system auth must not enable PIN.
      expect(controller.localProtectionStatus!.mode, LocalProtectionMode.system);
      expect(controller.localProtectionStatus!.pinSetupAvailable, isFalse);
      expect(value.capabilities, isEmpty);
      expect(controller.canEnterVault, isFalse);
      expect(controller.environments, isEmpty);
      expect(controller.devices, isEmpty);
      expect(controller.checkpoint, 0);
      expect(controller.navigate(VaultPage.environments), isFalse);

      // A read-only capability recovery cannot resurrect the previous view.
      systemCapability = 'SYSTEM_READY';
      await controller.refreshLocalProtection();
      expect(controller.canEnterVault, isFalse);
      expect(controller.environments, isEmpty);
      expect(port.calls.length, callsBefore);
      controller.dispose();
    });
  }

  test('protection state failure hides cached plaintext and cannot fall back after known PIN', () async {
    final port = PINPortFixture();
    var phase = 'missing';
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (phase == 'missing') throw MissingPluginException();
      if (phase == 'pin') return status(mode: 'pin', exists: true, ready: true);
      if (phase == 'corrupt') {
        throw PlatformException(code: 'LOCAL_PROTECTION_STATE');
      }
      throw PlatformException(code: 'UNSUPPORTED');
    });
    final value = NativeVaultGateway(
      experimentalOptIn: true,
      port: port,
      verifiedPINOperations: {
        'pull',
        'restoreSession',
        'businessPendingInfo',
        'setVariable',
      },
      inspector: (_) async => const InstanceDescriptor(
        initialRegistrationAvailable: false,
        allowRegistration: true,
        emailVerificationRequired: false,
      ),
    );
    final controller = VaultController(gateway: value);
    await controller.initialize();
    await controller.connectServer(endpoint);
    await controller.unlockSavedDevice();
    expect(controller.canEnterVault, true);
    expect(controller.environments, isNotEmpty);
    phase = 'pin';
    await controller.refreshLocalProtection();
    expect(controller.localProtectionStatus!.mode, LocalProtectionMode.pin);
    phase = 'corrupt';
    await controller.refreshLocalProtection();
    expect(controller.canEnterVault, false);
    expect(controller.environments, isEmpty);
    expect(value.capabilities, isEmpty);
    expect(controller.localProtectionStatus!.mode, LocalProtectionMode.blocked);
    phase = 'unsupported';
    await controller.refreshLocalProtection();
    expect(value.capabilities, isEmpty);
    expect(controller.canEnterVault, false);
    expect(controller.localProtectionStatus!.pinSetupAvailable, false);
    controller.dispose();
  });
}
