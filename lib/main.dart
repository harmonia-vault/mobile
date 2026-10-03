import 'dart:async';

import 'package:flutter/widgets.dart';

import 'native/native_vault_gateway.dart';
import 'ui/harmonia_app.dart';
import 'vault_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const preview = bool.fromEnvironment('HARMONIA_PREVIEW', defaultValue: false);
  const experimental = bool.fromEnvironment(
    'HARMONIA_NATIVE_EXPERIMENTAL',
    defaultValue: false,
  );
  final VaultGateway gateway = preview
      ? SyntheticPreviewGateway()
      : experimental
      ? NativeVaultGateway(experimentalOptIn: true)
      : PublicConnectionGateway();
  final controller = VaultController(gateway: gateway, allowPreview: preview);
  runApp(HarmoniaApp(controller: controller));
  unawaited(controller.initialize());
}
