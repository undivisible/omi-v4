import 'dart:async';

import 'package:omi/ui/omi_ui.dart';

/// Flutter loads this for every test in the package. The Omi mark rotates
/// forever in production; held still here so `pumpAndSettle` can return on any
/// screen that shows it.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  debugOmiOrbStatic = true;
  await testMain();
}
