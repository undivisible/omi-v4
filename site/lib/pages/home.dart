import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/omi_mark.dart';
import '../components/shell.dart';

/// One row of "What it does": a two-digit index, a claim, and the sentence
/// that earns it.
class _Capability {
  const _Capability(this.index, this.title, this.body);

  final String index;
  final String title;
  final String body;
}

const _capabilities = [
  _Capability(
    '01',
    'Memory with evidence',
    'Every fact keeps a citation back to the moment it came from. Correct it '
        'or delete it, and what was derived from it goes too.',
  ),
  _Capability(
    '02',
    'Live meetings',
    'Transcription and insight while the meeting is still happening.',
  ),
  _Capability(
    '03',
    'Currents',
    'What matters next, ranked and cited — re-ranked by what you dismiss or '
        'accept.',
  ),
  _Capability(
    '04',
    'Voice on a shake',
    'Shake the cursor, or tap both Shift keys. No window, no hotkey to '
        'remember.',
  ),
  _Capability(
    '05',
    'Computer use, approved',
    'It proposes, you approve, and the outcome lands in an append-only ledger.',
  ),
  _Capability(
    '06',
    'The pendant',
    'Captures the day over Bluetooth LE. Your phone relays; your desktop '
        'remembers.',
  ),
];

class Home extends StatelessComponent {
  const Home({super.key});

  @override
  Component build(BuildContext context) {
    return Page(
      title: 'Omi — your private second brain',
      description:
          'Omi is a private, second-brain personal AI: evidenced memory, live '
          'meetings, currents, a voice summon, a pendant, and an MCP server. '
          'Open source, local first.',
      path: '/',
      rail: const [
        ('top', 'Omi'),
        ('what', 'What it does'),
        ('api', 'API'),
        ('privacy', 'Privacy'),
        ('pricing', 'Pricing'),
      ],
      children: [
        _hero(),
        _whatItDoes(),
        _openSurface(),
        _privacy(),
        _pricing(),
      ],
    );
  }

  Component _hero() {
    return section(
      [
        const OmiMark.hero(),
        div([
          p([.text('Omi — 2026')], classes: 'label rise d1'),
          h1(
            [.text('A second brain that actually remembers.')],
            classes: 'giant rise d2',
            id: 't1',
          ),
          div([
            p([
              .text(
                'One hub across desktop, mobile and the web. It listens with '
                'you, and every answer cites where it came from.',
              ),
            ], classes: 'mid rise d3'),
            div([
              a([.text('Open Omi')], classes: 'btn btn-solid', href: portalUrl),
              a(
                [.text('What it does')],
                classes: 'btn btn-line',
                href: '#what',
              ),
            ], classes: 'links rise d4'),
          ], classes: 'hero-foot'),
        ], classes: 'hero-grid'),
        const _HubEmbed(),
      ],
      classes: 'hero wrap',
      id: 'top',
      attributes: {'aria-labelledby': 't1'},
    );
  }

  Component _whatItDoes() {
    return section(
      [
        h2([.text('What it does')], classes: 'label', id: 't2'),
        ol([
          for (final item in _capabilities)
            li([
              span([.text(item.index)], classes: 'label'),
              h3([.text(item.title)]),
              p([.text(item.body)]),
            ], classes: 'reveal'),
        ], classes: 'rows'),
      ],
      classes: 'band wrap',
      id: 'what',
      attributes: {'aria-labelledby': 't2'},
    );
  }

  Component _openSurface() {
    return section(
      [
        h2([.text('Open surface')], classes: 'label', id: 't3'),
        p([
          // Jaspr has no `sup` helper, so the element is named directly.
          Component.element(tag: 'sup', children: [.text('POST')]),
          .text('/mcp'),
        ], classes: 'mega reveal'),
        div([
          p([
            .text(
              'A public HTTP API and an MCP server, so the tools you already '
              'use can ask your second brain too.',
            ),
          ], classes: 'mid measure reveal'),
          ul([
            li([
              b([.text('The same boundary as the app.')]),
              .text(
                ' Every request carries your credential; every row is scoped to '
                'your account before it is read.',
              ),
            ]),
            li([
              b([.text('OpenAI-compatible chat.')]),
              .text(' '),
              code([.text('/v1/chat/completions')]),
              .text(' streams in the shape your clients already speak.'),
            ]),
            li([
              a(
                [.text('Read the API reference')],
                classes: 'arrow',
                href: '/docs/api',
              ),
            ]),
            li([
              a(
                [.text('See how it is built')],
                classes: 'arrow',
                href: '/architecture',
              ),
            ]),
          ], classes: 'notes reveal'),
        ], classes: 'split'),
      ],
      classes: 'band wrap',
      id: 'api',
      attributes: {'aria-labelledby': 't3'},
    );
  }

  Component _privacy() {
    return section(
      [
        h2([.text('Privacy')], classes: 'label', id: 't4'),
        p([
          .text('Your memory lives on your machine.'),
        ], classes: 'big reveal measure-tight'),
        ul([
          li([
            b([.text('Local source of truth.')]),
            .text(' The cloud keeps only a rebuildable projection for recall.'),
          ]),
          li([
            b([.text('On-device summaries.')]),
            .text(
              ' The workspace scan reads metadata, and on Apple silicon it '
              'summarises with no network call.',
            ),
          ]),
          li([
            b([.text('Open source.')]),
            .text(
              ' The line between local and cloud is something you can read.',
            ),
          ]),
        ], classes: 'notes split reveal'),
      ],
      classes: 'band wrap',
      id: 'privacy',
      attributes: {'aria-labelledby': 't4'},
    );
  }

  Component _pricing() {
    return section(
      [
        h2([.text('Pricing')], classes: 'label', id: 't5'),
        div([
          article([
            h3([.text('Omi')], classes: 'label'),
            p([
              .text('Free '),
              span([.text('+ your own keys')]),
            ], classes: 'amount'),
            p([
              .text('About \$5 a month, paid straight to your provider.'),
            ], classes: 'small'),
            a(
              [.text('Start with your key')],
              classes: 'btn btn-line',
              href: portalUrl,
            ),
          ], classes: 'plan reveal'),
          article([
            h3([.text('Omi AI')], classes: 'label'),
            p([
              .text('~\$35'),
              span([.text(' / month, managed')]),
            ], classes: 'amount'),
            p([
              .text('No keys, no provider accounts. We run them.'),
            ], classes: 'small'),
            a([.text('Open Omi')], classes: 'btn btn-solid', href: portalUrl),
          ], classes: 'plan reveal'),
        ], classes: 'plans'),
      ],
      classes: 'band wrap',
      id: 'pricing',
      attributes: {'aria-labelledby': 't5'},
    );
  }
}

/// The real hub, running in the page, in demo mode.
///
/// `/hub/` is built with `--dart-define=OMI_DEMO=1`, which boots the real
/// `OmiShell` against the seeded in-process services in `app/lib/demo/`. It
/// signs nobody in and makes no network request, so the frame is inert from
/// this document's point of view as well as the reader's.
///
/// The Flutter web build is several megabytes over the wire, so nothing is
/// fetched until the reader asks for it: until then the frame holds a still
/// drawn entirely in CSS, and the frame reserves its box up front so promoting
/// the still to the live app never shifts the layout. `web/main.js` swaps in
/// the iframe on click and falls back to a link if it cannot start.
///
/// This is an iframe onto the standalone `/hub/` build rather than an inline
/// Flutter element. See README.md for the measurements behind that: mounting
/// the app inline costs every page of the site ~130 KB of brotli-compressed
/// JavaScript before the reader has clicked anything, and the iframe costs
/// nothing until they do. The iframe also keeps the app's canvas, its errors
/// and its sign-in state out of this document.
class _HubEmbed extends StatelessComponent {
  const _HubEmbed();

  @override
  Component build(BuildContext context) {
    return figure([
      div(
        [
          div(
            [
              div([
                span([]),
                span([]),
                span([]),
                span([]),
              ], classes: 'still-rail'),
              div([
                p([], classes: 'still-line w70'),
                p([], classes: 'still-line w45'),
                p([], classes: 'still-line w60'),
                p([], classes: 'still-cite'),
                p([], classes: 'still-composer'),
              ], classes: 'still-thread'),
              div([
                p([], classes: 'still-line w80'),
                p([], classes: 'still-line w55'),
                p([], classes: 'still-line w65'),
              ], classes: 'still-side'),
            ],
            classes: 'shot-still',
            attributes: {'aria-hidden': 'true'},
          ),
          div([
            button(
              [.text('Try the hub')],
              classes: 'btn btn-solid',
              id: 'hub-start',
              type: ButtonType.button,
            ),
            p(
              [
                .text(
                  'The real app, compiled to the web, on sample data — about '
                  '5 MB, so it loads only when you ask for it. No sign-in, and '
                  'nothing you do in it leaves your browser.',
                ),
              ],
              classes: 'shot-note',
              id: 'hub-note',
            ),
          ], classes: 'shot-cta'),
        ],
        classes: 'shot-frame',
        id: 'hub-frame',
        attributes: {'data-state': 'idle'},
      ),
      figcaption([
        .text(
          'The hub itself, running in this page against seeded sample data — '
          'not anyone\'s account. Capture, the pendant, on-device '
          'transcription and computer use need the desktop build and say so '
          'here; everything else is the same UI, the same code.',
        ),
      ]),
    ], classes: 'shot reveal');
  }
}
