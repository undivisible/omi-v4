import 'dart:async';

import 'package:crepuscularity_flutter/crepuscularity_flutter.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Reads an optional AI-authored `.crepus` widget description from a current's
/// metadata. The model emits a constrained `.crepus` string; the
/// `crepuscularity_flutter` package parses and renders it. Absent or blank →
/// null, and the caller keeps the classic task row (non-breaking).
String? currentCrepusSource(Map<String, Object?>? metadata) {
  final value = metadata?['crepus'];
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// The palette the renderer uses, sourced from the hub theme by the caller so
/// this file stays independent of the private `_HubColors`.
class CrepusCurrentPalette {
  const CrepusCurrentPalette({
    required this.ink,
    required this.muted,
    required this.hairline,
    required this.cardBg,
    required this.cardShadow,
    required this.accent,
    required this.rowHover,
  });

  final Color ink;
  final Color muted;
  final Color hairline;
  final Color cardBg;
  final Color cardShadow;
  final Color accent;
  final Color rowHover;
}

/// A current rendered from AI-authored `.crepus`, in the same slot the classic
/// rich task row would occupy.
class CrepusCurrentRow extends StatelessWidget {
  const CrepusCurrentRow({
    required this.source,
    required this.palette,
    required this.onPrompt,
    required this.proposedNextStep,
    this.onComplete,
    super.key,
  });

  final String source;
  final CrepusCurrentPalette palette;
  final ValueChanged<String> onPrompt;
  final String proposedNextStep;
  final VoidCallback? onComplete;

  // ── ACTION WHITELIST — SECURITY BOUNDARY ───────────────────────────────────
  //
  // `crepuscularity_flutter` is generic and never interprets actions: it hands
  // the raw `on_click`/`on_change`/`on_long_press` string straight here. This
  // method is the ONLY place a current's action string becomes an effect, and
  // it maps a FIXED, closed set of prefixes to the existing current flow.
  // Anything not matched is inert. There is no `eval`, no dynamic dispatch, and
  // no arbitrary code path — a hostile or malformed action can, at most, do
  // nothing. Keep this allowlist exhaustive and small.
  void _dispatch(String action) {
    if (action == 'complete') {
      onComplete?.call();
      return;
    }
    if (action == 'accept') {
      // Mirrors the existing accept/handoff: prompt with the proposed step.
      onPrompt(proposedNextStep);
      return;
    }
    const promptPrefix = 'prompt:';
    if (action.startsWith(promptPrefix)) {
      final text = action.substring(promptPrefix.length).trim();
      if (text.isNotEmpty) onPrompt(text);
      return;
    }
    const openPrefix = 'open:';
    if (action.startsWith(openPrefix)) {
      final uri = Uri.tryParse(action.substring(openPrefix.length).trim());
      // Same URL safety as the rest of the app: external http(s) links only.
      if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
        unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
      }
      return;
    }
    // Unrecognised action → intentionally inert.
  }

  @override
  Widget build(BuildContext context) {
    final theme = CrepusTheme(
      textColor: palette.ink,
      mutedColor: palette.muted,
      accentColor: palette.accent,
      surfaceColor: palette.cardBg,
      borderColor: palette.hairline,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.hairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (onComplete != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 16),
                child: InkWell(
                  key: const Key('crepus_current_complete'),
                  onTap: onComplete,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: palette.muted),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.cardBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: palette.hairline),
                  boxShadow: [
                    BoxShadow(
                      color: palette.cardShadow,
                      offset: const Offset(0, 4),
                      blurRadius: 16,
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: CrepusView.fromSource(
                    source,
                    theme: theme,
                    onAction: _dispatch,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
