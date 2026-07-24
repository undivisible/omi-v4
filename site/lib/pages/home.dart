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

/// The device's published specification, as omi.me lists it.
const _specs = <(String, String)>[
  ('Size', '2.5cm diameter, 1.5cm deep'),
  ('Battery', '150 mAh, 10–14 hours'),
  ('Radio', 'Bluetooth 5.1; Wi-Fi 2.4/5 GHz'),
  ('Latency', '500–2000 ms live; 10–20 s offline'),
  ('Offline recording', 'Yes — it catches up when the phone is back'),
  ('Charging', 'Dock with pogo-pin contacts'),
  ('Languages', '25+, single, multi, or translated'),
  ('In transit', 'TLS'),
  ('At rest', 'AES-256-GCM'),
  ('Training on your data', 'No'),
  ('Compatibility', 'iOS 15+, Android 7+, macOS, any browser'),
  ('Water resistance', 'None — keep it out of the shower'),
];

/// What the device does once it is on, grouped the way the product page groups
/// it. The wording is Omi's own.
const _hardwareCapabilities = <(String, List<String>)>[
  (
    'Capture everything',
    [
      'Transcribes everything you say and hear',
      'Automatic summaries, tasks and memories',
      'Speech profiles, so it knows who said what',
      'Live streaming or offline recording',
    ],
  ),
  (
    'Recall instantly',
    [
      'Search summaries, tasks and memories',
      'Ask Omi: it knows you, and it can search the web',
      'A daily recap in the evening',
      'Tap and talk — Omi answers on the spot',
    ],
  ),
  (
    'Automate your work',
    [
      'Sync tasks to the task manager you already use',
      'Custom summary templates per meeting type',
      'Folders and stars, so a week of capture stays navigable',
      'Share a transcript or a summary in one action',
    ],
  ),
];

/// One photograph from omi.me, vendored beside the stylesheet so the page
/// stays same-origin. Two widths, so a phone does not fetch the desktop file.
class _Shot extends StatelessComponent {
  const _Shot(this.name, this.alt, {this.wide = false});

  final String name;
  final String alt;

  /// A full-width plate rather than one of a pair.
  final bool wide;

  @override
  Component build(BuildContext context) {
    return img(
      src: '/$name-1200.webp',
      alt: alt,
      width: 1200,
      height: 670,
      classes: wide ? 'photo photo--wide reveal' : 'photo reveal',
      attributes: {
        'srcset': '/$name-640.webp 640w, /$name-1200.webp 1200w',
        'sizes': wide
            ? '(min-width: 60rem) 76rem, 100vw'
            : '(min-width: 60rem) 38rem, 100vw',
        'loading': 'lazy',
        'decoding': 'async',
      },
    );
  }
}

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
        ('hardware', 'Hardware'),
        ('api', 'API'),
        ('privacy', 'Privacy'),
        ('pricing', 'Pricing'),
        ('negotiate', 'Negotiate'),
      ],
      children: [
        _hero(),
        _whatItDoes(),
        _hardware(),
        _openSurface(),
        _privacy(),
        _pricing(),
        _negotiate(),
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
            div([const PrimaryActions()], classes: 'rise d4'),
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

  Component _hardware() {
    return section(
      [
        h2([.text('The hardware')], classes: 'label', id: 't6'),
        p([
          .text('Two and a half centimetres of listening.'),
        ], classes: 'big reveal measure-20'),
        _Shot(
          'omi-pendant',
          'The Omi pendant, 2.5cm across, on a display plinth.',
          wide: true,
        ),
        div([
          p([
            .text(
              'Omi is a 2.5cm disc, 1.5cm deep, on a lanyard or a wrist band. '
              'It records what you say and hear, streams it to your phone over '
              'Bluetooth LE 5.1, and keeps recording when the phone is out of '
              'range — the audio catches up when it comes back.',
            ),
          ], classes: 'mid measure reveal'),
          ul([
            for (final (term, value) in _specs)
              li([
                b([.text(term)]),
                .text(value),
              ]),
          ], classes: 'notes specs reveal'),
        ], classes: 'split band-gap'),
        div([
          _Shot('omi-worn', 'Omi worn on a lanyard in an open-plan office.'),
          _Shot('omi-desk', 'Omi on a meeting-room table beside two laptops.'),
        ], classes: 'shot-pair band-gap'),
        div([
          for (final (title, lines) in _hardwareCapabilities)
            article([
              h3([.text(title)], classes: 'label'),
              ul([
                for (final line in lines) li([.text(line)]),
              ]),
            ], classes: 'card reveal'),
        ], classes: 'cards'),
        p([
          .text(
            'Omi is open hardware as well as open software: the enclosure, the '
            'board and the firmware are published, and this build talks to the '
            'same device.',
          ),
        ], classes: 'small measure band-gap reveal'),
      ],
      classes: 'band wrap',
      id: 'hardware',
      attributes: {'aria-labelledby': 't6'},
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
            h3([.text('Omi with your own keys')], classes: 'label'),
            p([.text('Negotiable')], classes: 'amount'),
            p([
              .text(
                'Sign in with an xAI or ChatGPT subscription you already pay '
                'for and there is no separate inference bill, or bring an API '
                'key for OpenAI, Anthropic, Gemini or a compatible endpoint '
                'and pay that provider directly. Either way, what you settle '
                'with Omi is Omi’s own price, and that is the figure you '
                'negotiate.',
              ),
            ], classes: 'small'),
            a(
              [.text('Negotiate')],
              classes: 'btn btn-line',
              href: '#negotiate',
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

  /// The joke is that the button does what it says. `worker/src/byok-pricing.ts`
  /// holds the band and `worker/src/byok-negotiation.ts` runs the conversation;
  /// `docs/byok.md` is the written version of both.
  Component _negotiate() {
    return section(
      [
        h2([.text('Negotiate')], classes: 'label', id: 't7'),
        p([
          .text('Haggle with Omi. It is not a metaphor.'),
        ], classes: 'big reveal measure-tight'),
        div([
          p([
            .text(
              'Bring your own key and the price is not a plan you pick, it is '
              'a conversation you have. Omi opens a session, you argue your '
              'case, and what you agree is what you are charged — because the '
              'agreement is enforced on the server, not in the app.',
            ),
          ], classes: 'mid measure reveal'),
          ul([
            li([
              b([.text('The model never sets the price.')]),
              .text(
                ' It may suggest at most one concession per reply, from a '
                'closed list the server sent it. The server turns codes into '
                'money.',
              ),
            ]),
            li([
              b([.text('There is a floor.')]),
              .text(
                ' Grants are de-duplicated, subtracted from the standard '
                'price, and clamped. No combination — forged or replayed — '
                'lands below it.',
              ),
            ]),
            li([
              b([.text('The prose cannot lie.')]),
              .text(
                ' Any figure in a reply is rewritten to the figure the server '
                'computed before you ever see it.',
              ),
            ]),
            li([
              b([.text('Accepting recomputes.')]),
              .text(
                ' Checkout reads the agreed price server-side; no caller '
                'passes one in. The transcript is kept with the outcome.',
              ),
            ]),
            li([
              b([.text('Skipping is a real path.')]),
              .text(
                ' Take the standard price and it is recorded like any '
                'other outcome.',
              ),
            ]),
          ], classes: 'notes reveal'),
        ], classes: 'split'),
        div([
          a(
            [.text('Download Omi and negotiate')],
            classes: 'btn btn-solid',
            href: downloadUrl,
          ),
          a(
            [.text('How the band works')],
            classes: 'arrow',
            href: '/architecture',
          ),
        ], classes: 'links band-gap reveal'),
      ],
      classes: 'band wrap',
      id: 'negotiate',
      attributes: {'aria-labelledby': 't7'},
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
/// The Flutter web build is several megabytes over the wire — roughly 1.2 MB
/// of application gzipped, before canvaskit and its fonts — so it must never
/// be part of the initial page weight for a reader who does not scroll this
/// far. `web/main.js` watches the frame with an IntersectionObserver and swaps
/// the iframe in as the section approaches the viewport, so it arrives loaded
/// rather than waiting on a click. Until then the frame holds a still drawn
/// entirely in CSS, and it reserves its box up front so promoting the still to
/// the live app never shifts the layout. The button remains as the manual path
/// for browsers without an observer, and for readers who have asked for
/// reduced data.
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
                  'The real app, compiled to the web, on sample data. It '
                  'starts loading as this section reaches the screen, so a '
                  'reader who never scrolls here never pays for it. No '
                  'sign-in, and nothing you do in it leaves your browser.',
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
