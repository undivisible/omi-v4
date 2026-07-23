/// The dev-only assistant access the hub resolved.
///
/// The key itself, the places it may be put, and the model a no-account live
/// voice session opens against all live in the hub (`dev_gemini.rs`); this is
/// only the answer it sends back.
final class DevAssistantAccess {
  const DevAssistantAccess({
    this.credential,
    required this.liveModel,
    required this.missingKeyHint,
  });

  static const none = DevAssistantAccess(liveModel: '', missingKeyHint: '');

  /// The developer Gemini key, or null when the hub found none.
  final String? credential;

  /// The Gemini Live model a no-account voice session opens against.
  final String liveModel;

  /// Actionable "no key found" text naming every candidate location. Empty
  /// when a key was found. Never contains key material.
  final String missingKeyHint;
}

/// Test seam. When set, the app uses this instead of asking the hub — the
/// hub's own resolution is covered by `dev_gemini.rs`, and a widget test has
/// no repository, no `HOME`, and no native runtime to resolve against.
DevAssistantAccess? debugDevAssistantAccess;
