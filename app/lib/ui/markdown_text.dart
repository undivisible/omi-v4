import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

class AssistantMarkdown extends StatelessWidget {
  const AssistantMarkdown(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => GptMarkdown(
    text,
    onLinkTap: (url, title) {
      final uri = Uri.tryParse(url);
      if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
        launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    },
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
