import 'package:flutter/foundation.dart';

import 'rewind_models.dart';

/// The apps Rewind refuses to photograph out of the box. Password managers and
/// the system keychain are the obvious ones: a screenshot of an unlocked vault
/// is a plaintext credential dump sitting on disk, and no retention bound
/// makes that acceptable. This list is the default, not the whole story — the
/// user can add to it, and nothing removes an entry silently.
const kRewindDefaultDeniedBundleIds = <String>{
  'com.1password.1password',
  'com.1password.1password7',
  'com.agilebits.onepassword7',
  'com.agilebits.onepassword-osx',
  'com.bitwarden.desktop',
  'org.keepassxc.keepassxc',
  'com.dashlane.dashlanephoenix',
  'com.lastpass.lastpassmacdesktop',
  'in.sinew.Enpass-Desktop',
  'me.proton.pass.electron',
  'com.apple.keychainaccess',
  'com.apple.Passwords',
  'com.strongbox.mac.strongbox',
  'com.nordpass.macos',
  'com.callpod.keeper',
};

/// Window-title markers that mean "this window is a private browsing session".
/// Browsers do not expose an is-private flag to other processes, and the title
/// is the only signal that crosses the process boundary, so this is a
/// heuristic — but it is a conservative one: a false positive costs a missing
/// frame, a false negative costs a recorded private session.
const _privateWindowMarkers = <String>[
  'private browsing',
  'incognito',
  'inprivate',
  'private window',
  'privé', // Safari, French locale.
];

/// Why a frame was not taken. Carried into the UI so a user who wonders "is it
/// recording right now?" gets a truthful answer instead of a spinner.
enum RewindSkipReason {
  deniedApp,
  privateWindow,
  screenLocked,
  paused,
  idle,
  heartbeat,
  minimumInterval,
  busy,
  unchanged,
  noPermission,
}

/// The user-editable privacy configuration. Immutable; the service swaps whole
/// instances so a change can never be half-applied mid-capture.
@immutable
final class RewindPrivacySettings {
  const RewindPrivacySettings({
    this.deniedBundleIds = kRewindDefaultDeniedBundleIds,
    this.skipPrivateBrowsing = true,
    this.recordWindowTitles = true,
    this.readOnScreenText = true,
  });

  final Set<String> deniedBundleIds;

  /// Skip any window whose title looks like a private browsing session.
  final bool skipPrivateBrowsing;

  /// Window titles are the most useful thing in the timeline and also the most
  /// revealing. The user can turn them off and keep only app names.
  final bool recordWindowTitles;

  /// Run Apple's Vision text recognition over each stored frame, on-device,
  /// and keep the result so the timeline is searchable. Off means the frames
  /// stay images and nothing is transcribed.
  final bool readOnScreenText;

  RewindPrivacySettings copyWith({
    Set<String>? deniedBundleIds,
    bool? skipPrivateBrowsing,
    bool? recordWindowTitles,
    bool? readOnScreenText,
  }) => RewindPrivacySettings(
    deniedBundleIds: deniedBundleIds ?? this.deniedBundleIds,
    skipPrivateBrowsing: skipPrivateBrowsing ?? this.skipPrivateBrowsing,
    recordWindowTitles: recordWindowTitles ?? this.recordWindowTitles,
    readOnScreenText: readOnScreenText ?? this.readOnScreenText,
  );

  /// The reason this context must not be captured, or null when it may be.
  RewindSkipReason? denialFor(RewindWindowContext context) {
    final bundleId = context.bundleId;
    if (bundleId != null && deniedBundleIds.contains(bundleId)) {
      return RewindSkipReason.deniedApp;
    }
    if (skipPrivateBrowsing && looksPrivate(context.windowTitle)) {
      return RewindSkipReason.privateWindow;
    }
    return null;
  }

  static bool looksPrivate(String? windowTitle) {
    if (windowTitle == null) return false;
    final lower = windowTitle.toLowerCase();
    for (final marker in _privateWindowMarkers) {
      if (lower.contains(marker)) return true;
    }
    return false;
  }

  Map<String, Object?> toJson() => {
    'deniedBundleIds': deniedBundleIds.toList(growable: false)..sort(),
    'skipPrivateBrowsing': skipPrivateBrowsing,
    'recordWindowTitles': recordWindowTitles,
    'readOnScreenText': readOnScreenText,
  };

  static RewindPrivacySettings fromJson(Object? value) {
    if (value is! Map) return const RewindPrivacySettings();
    final denied = value['deniedBundleIds'];
    return RewindPrivacySettings(
      deniedBundleIds: denied is List
          ? {
              ...kRewindDefaultDeniedBundleIds,
              ...denied.whereType<String>().where((id) => id.trim().isNotEmpty),
            }
          : kRewindDefaultDeniedBundleIds,
      skipPrivateBrowsing: value['skipPrivateBrowsing'] as bool? ?? true,
      recordWindowTitles: value['recordWindowTitles'] as bool? ?? true,
      readOnScreenText: value['readOnScreenText'] as bool? ?? true,
    );
  }
}
