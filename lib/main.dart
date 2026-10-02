import 'dart:async';

import 'package:flutter/widgets.dart';

import 'ui/harmonia_app.dart';
import 'vault_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const preview = bool.fromEnvironment('HARMONIA_PREVIEW', defaultValue: false);
  final controller = VaultController(
    gateway: preview ? SyntheticPreviewGateway() : FailClosedGateway(),
  );
  runApp(HarmoniaApp(controller: controller));
  unawaited(controller.reload());
}
