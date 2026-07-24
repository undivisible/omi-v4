import 'package:flowtoken_flutter/flowtoken_flutter.dart';
import 'package:flutter/material.dart';

/// Assistant prose — static markdown when [streaming] is false, FlowToken diff
/// fade when a reply is still arriving.
class AssistantMarkdown extends StatelessWidget {
  const AssistantMarkdown(this.text, {this.streaming = false, super.key});

  final String text;
  final bool streaming;

  @override
  Widget build(BuildContext context) => AnimatedMarkdown(
    content: text,
    separator: FlowTokenSeparator.diff,
    animation: streaming ? FlowTokenAnimation.fadeIn : null,
    duration: const Duration(milliseconds: 320),
    textStyle: DefaultTextStyle.of(context).style,
  );
}

String stripInlineMarkdown(String text) => text
    .replaceAll('**', '')
    .replaceAll('*', '')
    .replaceAll('`', '')
    .replaceAll('#', '')
    .replaceAllMapped(RegExp(r'_+([^_]*)_+'), (match) => match.group(1) ?? '')
    .replaceAllMapped(
      RegExp(r'\[([^\]]*)\]\([^)]*\)'),
      (match) => match.group(1) ?? '',
    )
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
