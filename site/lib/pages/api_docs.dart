import 'dart:convert';
import 'dart:io';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:markdown/markdown.dart' as md;

import '../components/shell.dart';

/// The API reference, rendered from `docs/api.md`.
///
/// The markdown file is the written contract and stays the single source of
/// truth: it is read at build time and rendered to static HTML, so the
/// document in the repository and the page on the web cannot drift. Nothing
/// here runs in the browser.
class ApiDocs extends StatelessComponent {
  const ApiDocs({super.key});

  @override
  Component build(BuildContext context) {
    final source = _readContract();
    final sections = _headings(source);
    // `gitHubWeb` brings the heading-id syntaxes with it, so every `##` and
    // `###` in the contract lands with a slug the contents list can point at
    // and a reader can share.
    // Escaping stays on: the contract is prose, and a code span like
    // `{"scope":"<scope>"}` must reach the page as text rather than as a tag
    // the browser then tries to close.
    final document = md.Document(extensionSet: md.ExtensionSet.gitHubWeb);
    final body = _wrapTables(
      md.HtmlRenderer().render(
        document.parseLines(const LineSplitter().convert(source)),
      ),
    );

    return Page(
      title: 'Omi — API reference',
      description:
          'The Omi public API and MCP server: authentication, scopes, rate '
          'limits, REST endpoints and MCP tools. The written contract, '
          'rendered.',
      path: '/docs/api',
      children: [
        section(
          [
            div([
              p([.text('Reference')], classes: 'label rise d1'),
              h1([.text('The public API')], classes: 'giant rise d2', id: 't1'),
              div([
                p([
                  .text('Two surfaces on one credential: a REST API under '),
                  code([.text('/api/v1')]),
                  .text(' and an MCP server at '),
                  code([.text('/mcp')]),
                  .text('. Everything here is scoped to a single account.'),
                ], classes: 'mid rise d3'),
                div([const PrimaryActions()], classes: 'rise d4'),
              ], classes: 'hero-foot'),
            ], classes: 'hero-grid'),
          ],
          classes: 'hero hero--doc wrap',
          id: 'top',
          attributes: {'aria-labelledby': 't1'},
        ),
        section(
          [
            h2([.text('Contents')], classes: 'label', id: 't2'),
            ol([
              for (final (anchor, label) in sections)
                li([
                  a([.text(label)], href: '#$anchor'),
                ]),
            ], classes: 'toc'),
          ],
          classes: 'band wrap',
          id: 'contents',
          attributes: {'aria-labelledby': 't2'},
        ),
        section(
          [
            // The contract's own <h1> is dropped by _stripTitle so the page keeps
            // one top-level heading and the document's <h2>s sit directly under
            // this section.
            div([RawText(body)], classes: 'prose'),
          ],
          classes: 'band wrap',
          id: 'reference',
          attributes: {'aria-label': 'API reference'},
        ),
      ],
    );
  }
}

/// Puts each generated table in a scroller of its own.
///
/// The contract's tables are wider than a phone, and a table that overflows
/// takes the whole page sideways with it. Markdown has nowhere to hang a
/// wrapper, so one is added here: `tabindex="0"` because a region that scrolls
/// has to be reachable from the keyboard, and a role and label so that
/// focusable region announces itself as something rather than nothing.
String _wrapTables(String html) => html
    .replaceAll(
      '<table>',
      '<div class="table-scroll" tabindex="0" role="region" '
          'aria-label="Table, scrollable"><table>',
    )
    .replaceAll('</table>', '</table></div>');

/// Reads `docs/api.md`. Pre-rendering runs from the site package, but the
/// same code is used by `jaspr serve` from a different working directory, so
/// both are tried before giving up loudly — a docs page that silently renders
/// empty would be worse than a failed build.
String _readContract() {
  const candidates = ['../docs/api.md', 'docs/api.md'];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return _stripTitle(file.readAsStringSync());
  }
  throw StateError(
    'Could not find docs/api.md from ${Directory.current.path}. The API '
    'reference page renders that file and will not build without it.',
  );
}

/// Drops the contract's leading `# Omi Public API`, because the page supplies
/// its own `<h1>` and a document should have exactly one.
String _stripTitle(String source) {
  final lines = source.split('\n');
  final first = lines.indexWhere((row) => row.trim().isNotEmpty);
  if (first >= 0 && lines[first].startsWith('# ')) {
    return lines.sublist(first + 1).join('\n').trimLeft();
  }
  return source;
}

/// The `##` headings of the contract, paired with the slug the renderer will
/// give them, so the contents list and the document agree without a second
/// pass over the generated HTML.
List<(String, String)> _headings(String source) {
  final result = <(String, String)>[];
  for (final row in source.split('\n')) {
    if (!row.startsWith('## ')) continue;
    final label = row.substring(3).trim();
    result.add((_slug(label), label));
  }
  return result;
}

/// Mirrors `package:markdown`'s own slug generation: lowercase, strip
/// anything that is not a word character, space or hyphen, then hyphenate.
String _slug(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^\w\s-]'), '')
    .trim()
    .replaceAll(RegExp(r'\s+'), '-');
