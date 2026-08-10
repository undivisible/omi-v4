import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// The one durable home for Omi's local data. On desktop this is `~/.omi`, a
/// stable dot-directory that does NOT move when the bundle identifier changes
/// — the rename to me.omi.next orphaned everything under the old
/// Application Support folder, and a home-relative path never has that
/// problem. On mobile (no writable home) and web it falls back to a `.omi`
/// subfolder of the platform's private application-support area.
Future<Directory> omiDataDirectory() async {
  final directory = Directory(await _omiRootPath());
  await directory.create(recursive: true);
  await _restrictOwnerAccess(directory);
  return directory;
}

Future<void> _restrictOwnerAccess(Directory directory) async {
  if (kIsWeb) {
    return;
  }
  if (!(Platform.isMacOS || Platform.isLinux)) {
    return;
  }
  try {
    await Process.run('chmod', ['700', directory.path]);
  } catch (_) {}
}

Future<String> _omiRootPath() async {
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows)) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      return '$home${Platform.pathSeparator}.omi';
    }
  }
  // Mobile/web, or a desktop process with no home in its environment.
  return '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}.omi';
}
