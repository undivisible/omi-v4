import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/ui/markdown_text.dart';

String _visibleText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((rich) => rich.text.toPlainText())
    .join('\n');

void main() {
  testWidgets('assistant markdown renders bold, lists, and code', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AssistantMarkdown(
              '**Bold claim**\n\n- first item\n- second item\n\n`inline code`',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final visible = _visibleText(tester);
    expect(visible, contains('Bold claim'));
    expect(visible, contains('first item'));
    expect(visible, contains('second item'));
    expect(visible, contains('inline code'));
    expect(visible, isNot(contains('**')));
    expect(visible, isNot(contains('`')));
  });

  test('stripInlineMarkdown removes markers but keeps the words', () {
    expect(
      stripInlineMarkdown('**Ship the _release_** with `flags` # today'),
      'Ship the release with flags today',
    );
    expect(
      stripInlineMarkdown('See [the doc](https://example.test) for *details*'),
      'See the doc for details',
    );
    expect(stripInlineMarkdown('  plain   text  '), 'plain text');
  });
}
