import 'dart:async';

import 'package:omi/api/dev_assistant.dart';
import 'package:omi/ui/omi_ui.dart';

/// Flutter loads this for every test in the package. The Omi mark rotates
/// forever in production; held still here so `pumpAndSettle` can return on any
/// screen that shows it. Dev assistant access is answered by the hub, which no
/// widget test has; it resolves to "no key" here unless a test says otherwise.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  debugOmiOrbStatic = true;
  debugDevAssistantAccess = DevAssistantAccess.none;
  await testMain();
}
