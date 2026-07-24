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

/// Whether a `.crepus` source parses into something this renderer can actually
/// draw. The AI authors the brief, so its output is treated as untrusted input:
/// a document that is empty (blank, oversized, or over the node/depth caps) or
/// that references a node kind outside the renderer's allowlist is rejected
/// here, and the caller falls back to the hand-built brief rather than showing
/// a blank or half-drawn surface.
bool crepusRenders(String source) {
  final ir = viewIrFromSource(source);
  if (ir.root.isEmpty) return false;
  var text = false;
  bool walk(List<ViewNode> nodes) {
    for (final node in nodes) {
      if (node is UnsupportedNode) return false;
      if (node is TextNode && node.content.trim().isNotEmpty) text = true;
      if (node is ButtonNode && node.label.trim().isNotEmpty) text = true;
      if (!walk(childrenOf(node))) return false;
    }
    return true;
  }

  return walk(ir.root) && text;
}

// ── ACTION WHITELIST — SECURITY BOUNDARY ───────────────────────────────────
//
// `crepuscularity_flutter` is generic and never interprets actions: it hands
// the raw `on_click`/`on_change`/`on_long_press` string straight here. This
// method is the ONLY place a current's action string becomes an effect, and
// it maps a FIXED, closed set of prefixes to the existing current flow.
// Anything not matched is inert. There is no `eval`, no dynamic dispatch, and
// no arbitrary code path.
//
// Two of the matched kinds still carry model-authored payloads, so the closed
// set of kinds is not by itself the boundary. The button label comes from the
// same untrusted source as the action and can lie about what a tap does, so
// neither payload is ever acted on unattended:
//   * `open:` never launches silently. It shows a confirmation naming the
//     resolved host — read from the parsed URL, never from the label — and
//     launches only if the user agrees.
//   * `prompt:` only drafts into the composer. It never sends, so the exact
//     text is on screen before the user chooses to submit it.
//   * `compute:` sends the instruction as a prompt to start a task (a
//     computer-use turn acts on it). The instruction is visible in the card
//     before the tap, and the tap is the user's deliberate act.
// Keep this allowlist exhaustive and small.
Future<void> dispatchCrepusAction(
  String action, {
  required BuildContext context,
  required ValueChanged<String> onPrompt,
  required String proposedNextStep,
  ValueChanged<String>? onDraftPrompt,
  VoidCallback? onComplete,
}) async {
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
    // No draft sink means no way to show the text first, so the action is
    // dropped rather than sent behind the user's back.
    if (text.isNotEmpty) onDraftPrompt?.call(text);
    return;
  }
  const computePrefix = 'compute:';
  if (action.startsWith(computePrefix)) {
    // Launch a task: the instruction is sent as a prompt, which a
    // computer-use-capable assistant turn picks up and drives. Like `accept`
    // it goes through `onPrompt` (sent, not drafted) because starting the
    // session is the point — but the instruction is visible in the card
    // before the tap, and the tap is the user's deliberate act.
    final text = action.substring(computePrefix.length).trim();
    if (text.isNotEmpty) onPrompt(text);
    return;
  }
  const openPrefix = 'open:';
  if (action.startsWith(openPrefix)) {
    final uri = Uri.tryParse(action.substring(openPrefix.length).trim());
    // Same URL safety as the rest of the app: external http(s) links only.
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return;
    if (uri.host.isEmpty) return;
    if (!await confirmCrepusOpen(context, uri)) return;
    unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
    return;
  }
  // Unrecognised action → intentionally inert.
}

/// The confirmation shown before a model-authored `open:` link is launched.
/// It names the resolved host from the parsed URL; the button's own label is
/// deliberately not shown here, because it is untrusted and may describe a
/// destination the link does not go to.
Future<bool> confirmCrepusOpen(BuildContext context, Uri uri) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('crepus_open_confirm'),
      title: const Text('Open external link?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('This link was written by the assistant. It opens:'),
          const SizedBox(height: 8),
          Text(uri.host, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('crepus_open_cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('crepus_open_confirm_action'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Open'),
        ),
      ],
    ),
  );
  return agreed ?? false;
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

/// The renderer theme for a hub palette, so every crepus surface in the app
/// (row and brief alike) resolves colours identically.
CrepusTheme crepusThemeFor(CrepusCurrentPalette palette) => CrepusTheme(
  textColor: palette.ink,
  mutedColor: palette.muted,
  accentColor: palette.accent,
  surfaceColor: palette.cardBg,
  borderColor: palette.hairline,
);

/// A current rendered from AI-authored `.crepus`, in the same slot the classic
/// rich task row would occupy.
class CrepusCurrentRow extends StatelessWidget {
  const CrepusCurrentRow({
    required this.source,
    required this.palette,
    required this.onPrompt,
    required this.proposedNextStep,
    this.onDraftPrompt,
    this.onComplete,
    super.key,
  });

  final String source;
  final CrepusCurrentPalette palette;
  final ValueChanged<String> onPrompt;
  final String proposedNextStep;
  final ValueChanged<String>? onDraftPrompt;
  final VoidCallback? onComplete;

  @override
  Widget build(BuildContext context) {
    final theme = crepusThemeFor(palette);
    // The single dispatch entry point lives at file scope so the brief renders
    // AI-authored actions through exactly the same whitelist as this row.
    void dispatch(String action) => unawaited(
      dispatchCrepusAction(
        action,
        context: context,
        onPrompt: onPrompt,
        proposedNextStep: proposedNextStep,
        onDraftPrompt: onDraftPrompt,
        onComplete: onComplete,
      ),
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
                    onAction: dispatch,
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
