import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CoreCapability {
  accessibility,
  microphone,
  screenCapture,
  appData,
  workspaceRoot,
}

enum CapabilityState {
  checking,
  granted,
  actionRequired,
  notRequired,
  notApplicable,
  error,
}

final class CapabilityStatus {
  const CapabilityStatus({required this.state, required this.detail});

  final CapabilityState state;
  final String detail;

  bool get acceptable =>
      state == CapabilityState.granted ||
      state == CapabilityState.notRequired ||
      state == CapabilityState.notApplicable;
}

abstract interface class DesktopCapabilityGateway {
  Future<Map<CoreCapability, CapabilityStatus>> check();

  Future<void> request(CoreCapability capability);
}

abstract interface class WorkspaceRootStore {
  Future<String?> read();

  Future<void> write(String path);

  Future<void> clear();
}

final class PreferencesWorkspaceRootStore implements WorkspaceRootStore {
  static const _key = 'omi.workspace_root.v1';

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(_key);

  @override
  Future<void> write(String path) async {
    final saved = await (await SharedPreferences.getInstance()).setString(
      _key,
      path,
    );
    if (!saved) throw StateError('Could not save the workspace root.');
  }

  @override
  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    if (preferences.containsKey(_key) && !await preferences.remove(_key)) {
      throw StateError('Could not clear the workspace root.');
    }
  }
}

final class VolatileWorkspaceRootStore implements WorkspaceRootStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String path) async => value = path;

  @override
  Future<void> clear() async => value = null;
}

final class PlatformDesktopCapabilityGateway
    implements DesktopCapabilityGateway {
  PlatformDesktopCapabilityGateway({
    WorkspaceRootStore? workspaceRoots,
    Future<String?> Function()? directoryPicker,
  }) : workspaceRoots = workspaceRoots ?? PreferencesWorkspaceRootStore(),
       _directoryPicker = directoryPicker ?? _pickDirectory;

  static const _channel = MethodChannel('omi/core_capabilities');
  final WorkspaceRootStore workspaceRoots;
  final Future<String?> Function() _directoryPicker;
  Future<void>? _workspaceRequest;

  Future<String?> verifiedWorkspaceRoot() async {
    if (!_supportsWorkspace) return null;
    return (await _checkWorkspaceRoot()).path;
  }

  bool get _supportsWorkspace =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  static Future<String?> _pickDirectory() =>
      getDirectoryPath(confirmButtonText: 'Use this workspace');

  @override
  Future<Map<CoreCapability, CapabilityStatus>> check() async {
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return {
        for (final capability in CoreCapability.values)
          capability: const CapabilityStatus(
            state: CapabilityState.notApplicable,
            detail: 'Desktop capability; not applicable on this device.',
          ),
      };
    }
    final appData = await _checkAppData();
    final workspaceRoot = (await _checkWorkspaceRoot()).status;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      try {
        final values = await _channel.invokeMapMethod<String, bool>('check');
        return {
          CoreCapability.accessibility: const CapabilityStatus(
            state: CapabilityState.notRequired,
            detail:
                'Windows UI Automation has no separate permission grant. Actions remain limited by process integrity.',
          ),
          CoreCapability.microphone: _permission(
            values?['microphone'] == true,
            'Windows microphone privacy access is required for voice capture.',
          ),
          CoreCapability.screenCapture: const CapabilityStatus(
            state: CapabilityState.notRequired,
            detail:
                'Windows asks for a window or display when each capture session starts.',
          ),
          CoreCapability.appData: appData,
          CoreCapability.workspaceRoot: workspaceRoot,
        };
      } catch (error) {
        return {
          CoreCapability.accessibility: const CapabilityStatus(
            state: CapabilityState.notRequired,
            detail:
                'Windows UI Automation has no separate permission grant. Actions remain limited by process integrity.',
          ),
          CoreCapability.microphone: CapabilityStatus(
            state: CapabilityState.error,
            detail: 'Could not check Windows microphone access: $error',
          ),
          CoreCapability.screenCapture: const CapabilityStatus(
            state: CapabilityState.notRequired,
            detail:
                'Windows asks for a window or display when each capture session starts.',
          ),
          CoreCapability.appData: appData,
          CoreCapability.workspaceRoot: workspaceRoot,
        };
      }
    }
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      return {
        for (final capability in CoreCapability.values)
          capability: capability == CoreCapability.appData
              ? appData
              : capability == CoreCapability.workspaceRoot
              ? workspaceRoot
              : const CapabilityStatus(
                  state: CapabilityState.error,
                  detail:
                      'This desktop capability has no verified implementation, so production setup stays blocked.',
                ),
      };
    }
    try {
      final values = await _channel.invokeMapMethod<String, bool>('check');
      return {
        CoreCapability.accessibility: _permission(
          values?['accessibility'] == true,
          'Accessibility lets Omi identify and act in the active app.',
        ),
        CoreCapability.microphone: _permission(
          values?['microphone'] == true,
          'Microphone access is required for voice and meeting capture.',
        ),
        CoreCapability.screenCapture: _permission(
          values?['screenCapture'] == true,
          'Screen Recording lets Omi understand visible work.',
        ),
        CoreCapability.appData: _permission(
          values?['fullDiskAccess'] == true,
          'Full Disk Access lets Omi read Apple Mail and Notes for your local memory.',
        ),
        CoreCapability.workspaceRoot: workspaceRoot,
      };
    } catch (error) {
      return {
        for (final capability in CoreCapability.values)
          capability: capability == CoreCapability.appData
              ? appData
              : capability == CoreCapability.workspaceRoot
              ? workspaceRoot
              : CapabilityStatus(
                  state: CapabilityState.error,
                  detail: 'Could not check this capability: $error',
                ),
      };
    }
  }

  @override
  Future<void> request(CoreCapability capability) async {
    if (kIsWeb) return;
    if (capability == CoreCapability.workspaceRoot) {
      if (!_supportsWorkspace) return;
      final pending = _workspaceRequest;
      if (pending != null) return pending;
      final operation = _selectWorkspaceRoot();
      _workspaceRequest = operation;
      try {
        await operation;
      } finally {
        if (identical(_workspaceRequest, operation)) _workspaceRequest = null;
      }
      return;
    }
    if ((defaultTargetPlatform != TargetPlatform.macOS &&
            defaultTargetPlatform != TargetPlatform.windows) ||
        capability == CoreCapability.appData &&
            defaultTargetPlatform != TargetPlatform.macOS) {
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.windows &&
        capability != CoreCapability.microphone) {
      return;
    }
    await _channel.invokeMethod<void>('request', capability.name);
  }

  Future<void> _selectWorkspaceRoot() async {
    final selected = await _directoryPicker();
    if (selected == null) return;
    try {
      final canonical = await Directory(selected).resolveSymbolicLinks();
      await _probe(Directory(canonical));
      await workspaceRoots.write(canonical);
    } catch (error, stackTrace) {
      await _clearWorkspaceRoot();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  CapabilityStatus _permission(bool granted, String detail) => CapabilityStatus(
    state: granted ? CapabilityState.granted : CapabilityState.actionRequired,
    detail: detail,
  );

  Future<CapabilityStatus> _checkAppData() async {
    try {
      final directory = await getApplicationSupportDirectory();
      await directory.create(recursive: true);
      await _probe(directory);
      return CapabilityStatus(
        state: CapabilityState.granted,
        detail: 'Private app-data access verified at ${directory.path}.',
      );
    } catch (error) {
      return CapabilityStatus(
        state: CapabilityState.error,
        detail: 'Private app-data access is unavailable: $error',
      );
    }
  }

  Future<({CapabilityStatus status, String? path})>
  _checkWorkspaceRoot() async {
    final path = await workspaceRoots.read();
    if (path == null) {
      return (
        status: const CapabilityStatus(
          state: CapabilityState.actionRequired,
          detail:
              'Choose a concrete workspace folder. Omi will verify read and write access only for that folder.',
        ),
        path: null,
      );
    }
    try {
      final canonical = await Directory(path).resolveSymbolicLinks();
      await _probe(Directory(canonical));
      if (canonical != path) await workspaceRoots.write(canonical);
      return (
        status: CapabilityStatus(
          state: CapabilityState.granted,
          detail: 'Workspace read and write access verified for $canonical.',
        ),
        path: canonical,
      );
    } catch (error) {
      await _clearWorkspaceRoot();
      return (
        status: CapabilityStatus(
          state: CapabilityState.actionRequired,
          detail: 'The saved workspace is unavailable. Choose it again. $error',
        ),
        path: null,
      );
    }
  }

  Future<void> _clearWorkspaceRoot() async {
    try {
      await workspaceRoots.clear();
    } catch (_) {}
  }

  Future<void> _probe(Directory directory) async {
    if (!await directory.exists()) {
      throw FileSystemException('Directory does not exist', directory.path);
    }
    await directory.list(followLinks: false).take(1).toList();
    final probe = File(
      '${directory.path}${Platform.pathSeparator}.omi-scope-check-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await probe.writeAsString('omi', flush: true);
      await probe.readAsString();
    } finally {
      if (await probe.exists()) await probe.delete();
    }
  }
}
