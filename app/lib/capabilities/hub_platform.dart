import 'package:flutter/foundation.dart';

/// Thin platform probes for what the hub UI may expose. Prefer these over
/// scattering `kIsWeb` / `defaultTargetPlatform` checks through widgets.
///
/// "The hub" is the continuous-chat shell backed by the in-process Rust
/// runtime on native desktop. The web portal reuses the same Flutter shell
/// but talks to the Worker instead of linking `app/native/hub/`.

bool get hubIsWeb => kIsWeb;

bool get hubIsDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

bool get hubIsMobile =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

/// The Rust hub is compiled into native binaries only; web uses Worker APIs.
bool get nativeHubLinked => !kIsWeb;

/// macOS/Windows duplex voice through the native hub (mic + Gemini Live).
bool get desktopVoiceSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows);

/// Meeting capture, system-audio transcription, and the assist panel.
bool get meetingAssistSupported => hubIsDesktop;

/// Accessibility computer-use on this machine (approve local actions).
bool get localComputerUseSupported => hubIsDesktop && nativeHubLinked;

/// Remote computer-use: delegate approved actions to a signed-in desktop.
bool get remoteComputerUseSupported => true;

/// FaceTime calling through the worker (desktop product surface).
bool get facetimeSupported => hubIsDesktop;

/// BLE pendant relay and capture WAL.
bool get pendantSupported => hubIsMobile;

/// Summoned pill, menu-bar status item, native settings window.
bool get desktopChromeSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Desktop onboarding (permissions, workspace scan, capture setup).
bool get desktopOnboardingSupported => hubIsDesktop;
