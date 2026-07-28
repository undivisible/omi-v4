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
    'Memory you can check',
    'Every fact keeps a trail back to where it came from. Correct it or '
        'delete it, and anything built on it updates with it.',
  ),
  _Capability(
    '02',
    'Live meetings',
    'Transcription and insight while the meeting is still going — live voice '
        'when you need a conversation, longer capture when you need the full '
        'record.',
  ),
  _Capability(
    '03',
    'Currents & Now Brief',
    'What matters next, ranked and cited — reshaped by what you dismiss or '
        'accept. Rich updates can show up as a clear Now Brief graphic.',
  ),
  _Capability(
    '04',
    'Voice on double-Shift',
    'Press both Shift keys — in the app, or from anywhere once you’ve '
        'allowed it. Voice opens in a small overlay so it doesn’t take over '
        'your screen.',
  ),
  _Capability(
    '05',
    'Clicks and typing, with your OK',
    'It asks before it clicks or types. You approve once; every action is '
        'recorded.',
  ),
  _Capability(
    '06',
    'The pendant',
    'Captures the day over Bluetooth. Your phone relays; your desktop '
        'remembers.',
  ),
  _Capability(
    '07',
    'Telegram & iMessage',
    'Link Telegram or iMessage in Settings. Messages join the same '
        'conversation as desktop — replies go back when you’re online.',
  ),
  _Capability(
    '08',
    'FaceTime calls',
    'Ask Omi to place a FaceTime Audio call to a phone number when calling '
        'is set up for your account.',
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
  ('Encrypted in transit', 'TLS'),
  ('Encrypted on disk', 'AES-256-GCM'),
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

/// Channel surfaces and how they connect back to the same conversation.
const _reachChannels = <(String, List<String>)>[
  (
    'Telegram',
    [
      'Link once in Settings with a short code',
      'Messages join the same conversation as desktop',
      'Replies stay plain text on Telegram',
      'Can ask Omi to help on your computer — with your OK',
    ],
  ),
  (
    'iMessage',
    [
      'Same linking flow with a short code from the app',
      'Messages join the same conversation as desktop',
      'You can ask Omi to help on your computer the same way — with your OK',
      'FaceTime Audio is available when calling is set up on your account',
    ],
  ),
  (
    'FaceTime',
    [
      'Omi can place a FaceTime Audio call to a phone number',
      'It rings their phone — not a join link',
      'Needs calling to be enabled for your account',
      'Same assistant memory as chat, Telegram, and iMessage',
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
      title: 'Omi — private memory that stays useful',
      description:
          'Omi keeps the thread across the moments you choose to remember, with a transparent guided demo before you connect anything.',
      path: '/',
      compactFooter: true,
      children: [hubHeroLegacy(), hubLegacy(), makeItYoursLegacy()],
    );
  }

  Component hubHeroLegacy() {
    return section(
      [
        div([
          const OmiMark.hero(),
          p([.text('OMI · GUIDED HUB')], classes: 'label rise d1'),
          h1(
            [.text('Life moves fast. Keep the thread.')],
            classes: 'giant rise d2',
            id: 'hub-hero-title',
          ),
          p([
            .text(
              'A private memory for the things you choose to keep — with sources, '
              'context, and a next step you can act on.',
            ),
          ], classes: 'mid rise d3'),
          div([
            a(
              [.text('Try the sample Hub ↓')],
              classes: 'btn btn-solid',
              href: '#hub',
            ),
            a(
              [.text('Open your Omi')],
              classes: 'btn btn-line',
              href: downloadUrl,
            ),
          ], classes: 'links rise d4'),
        ], classes: 'hub-hero-copy'),
        div([
          img(
            src: '/omi-pendant-product.png',
            alt: 'The Omi pendant.',
            width: 1103,
            height: 1287,
            classes: 'hub-pendant rise d3',
          ),
          span([.text('PENDANT · OPTIONAL')], classes: 'hub-measure'),
        ], classes: 'hub-hero-object'),
      ],
      classes: 'hub-hero wrap',
      id: 'top',
      attributes: {'aria-labelledby': 'hub-hero-title'},
    );
  }

  Component hubLegacy() {
    return section(
      [
        div([
          p([.text('TRY THE DEMO · SAMPLE DATA')], classes: 'label'),
          h2(
            [.text('See Omi make a moment useful.')],
            classes: 'big',
            id: 'hub-title',
          ),
          p([
            .text(
              'Explore a guided example before you connect anything. This Hub uses '
              'sample data, never your account.',
            ),
          ], classes: 'mid'),
        ], classes: 'hub-intro reveal'),
        const HubEmbedLegacy(),
      ],
      classes: 'hub-stage wrap',
      id: 'hub',
      attributes: {'aria-labelledby': 'hub-title'},
    );
  }

  Component makeItYoursLegacy() {
    return section(
      [
        div([
          p([.text('MAKE IT YOURS')], classes: 'label'),
          h2(
            [.text('Let it in, on your terms.')],
            classes: 'big',
            id: 'make-title',
          ),
        ], classes: 'hub-intro reveal'),
        div([
          article([
            span([.text('01')], classes: 'label'),
            h3([.text('Ask.')]),
            p([
              .text(
                'Chat, meetings, and the things you choose to capture become findable.',
              ),
            ]),
          ]),
          article([
            span([.text('02')], classes: 'label'),
            h3([.text('Connect Apple Calendar.')]),
            p([
              .text(
                'In the native app, grant Calendar and Reminders access. Omi can use that context and, if you enable it, mirror due Currents back.',
              ),
            ]),
          ]),
          article([
            span([.text('03')], classes: 'label'),
            h3([.text('Stay in control.')]),
            p([
              .text(
                'See the source. Correct it. Dismiss it. Omi acts only with your approval.',
              ),
            ]),
          ]),
        ], classes: 'hub-steps reveal'),
        div([
          p([
            .text(
              'No browser history. No hidden activity profile. Just the access you choose.',
            ),
          ]),
          a(
            [.text('Download Omi')],
            classes: 'btn btn-solid',
            href: downloadUrl,
          ),
        ], classes: 'hub-privacy reveal'),
      ],
      classes: 'hub-make wrap',
      id: 'make-it-yours',
      attributes: {'aria-labelledby': 'make-title'},
    );
  }

  Component heroLegacy() {
    return section(
      [
        div([
          p([.text('OMI · PRIVATE MEMORY')], classes: 'label rise d1'),
          h1(
            [.text('Be here. Omi keeps the thread.')],
            classes: 'giant rise d2',
            id: 't1',
          ),
          div([
            p([
              .text(
                'A private memory for the things that matter while you are busy '
                'living them.',
              ),
            ], classes: 'mid rise d3'),
            div([const PrimaryActions()], classes: 'rise d4'),
          ], classes: 'hero-foot'),
        ], classes: 'hero-grid'),
        div([
          const OmiMark.hero(),
          img(
            src: '/omi-pendant-product.png',
            alt: 'The Omi pendant.',
            width: 1103,
            height: 1287,
            classes: 'hero-pendant rise d3',
          ),
          span([.text('02.5 CM')], classes: 'pendant-measure'),
        ], classes: 'hero-object'),
      ],
      classes: 'hero wrap',
      id: 'top',
      attributes: {'aria-labelledby': 't1'},
    );
  }

  Component currentsLegacy() {
    return section(
      [
        div([
          p([.text('CURRENTS')], classes: 'label'),
          h2(
            [.text('Your attention, edited.')],
            classes: 'big',
            id: 'currents-title',
          ),
          p([.text('A few clear signals. Evidence attached.')], classes: 'mid'),
        ], classes: 'section-intro reveal'),
        const _CurrentsRecreation(),
      ],
      classes: 'currents-stage wrap',
      id: 'currents',
      attributes: {'aria-labelledby': 'currents-title'},
    );
  }

  Component pendantLegacy() {
    return section(
      [
        div([
          p([.text('THE PENDANT')], classes: 'label'),
          h2([.text('A quiet witness.')], classes: 'big', id: 'pendant-title'),
          p([
            .text('Wear it. Forget it. Find the moment later.'),
          ], classes: 'mid'),
          a(
            [.text('See Omi in the app')],
            classes: 'btn btn-solid',
            href: portalUrl,
          ),
        ], classes: 'pendant-copy reveal'),
        _Shot('omi-worn', 'Omi worn on a lanyard in an open-plan office.'),
        _Shot('omi-desk', 'Omi on a meeting-room table beside two laptops.'),
      ],
      classes: 'pendant-stage wrap',
      id: 'pendant',
      attributes: {'aria-labelledby': 'pendant-title'},
    );
  }

  Component whatItDoes() {
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

  Component memory() {
    return section(
      [
        h2([.text('Memory')], classes: 'label', id: 't8'),
        p([
          .text('Remembered once, available everywhere you use Omi.'),
        ], classes: 'big reveal measure-16'),
        ul([
          li([
            b([.text('On your computer.')]),
            .text(
              ' Omi keeps a private copy of what it has learned from chats, '
              'transcripts, and what it sees on screen — so recall still '
              'works when you’re offline.',
            ),
          ]),
          li([
            b([.text('Synced to your account.')]),
            .text(
              ' Nothing counts as remembered until it’s safely stored in your '
              'account. Your devices catch up from there — so they stay '
              'consistent, not invent their own version of the truth.',
            ),
          ]),
          li([
            b([.text('Offline, without guessing.')]),
            .text(
              ' Desktop can answer from the last sync. It may be a little '
              'behind; it won’t make things up. On the web, you always see '
              'what’s in your account.',
            ),
          ]),
          li([
            b([.text('Cited answers.')]),
            .text(
              ' Search and chat only return things they can point back to. If '
              'the source is gone, the answer is gone — not kept without a '
              'citation.',
            ),
          ]),
        ], classes: 'notes split reveal'),
        p([
          a(
            [.text('How remembering stays honest')],
            classes: 'arrow',
            href: '/architecture#memory',
          ),
        ], classes: 'links band-gap reveal'),
      ],
      classes: 'band wrap',
      id: 'memory',
      attributes: {'aria-labelledby': 't8'},
    );
  }

  Component reach() {
    return section(
      [
        h2([.text('Reach')], classes: 'label', id: 't9'),
        p([
          .text('Same brain, other inboxes.'),
        ], classes: 'big reveal measure-16'),
        div([
          for (final (title, lines) in _reachChannels)
            article([
              h3([.text(title)], classes: 'label'),
              ul([
                for (final line in lines) li([.text(line)]),
              ]),
            ], classes: 'card reveal'),
        ], classes: 'cards'),
        p([
          .text(
            'Link Telegram or iMessage in Settings with a short code from the '
            'app. Managed Omi AI billing rolls out when checkout is live; until '
            'then, bring your own keys or negotiate.',
          ),
        ], classes: 'small measure band-gap reveal'),
      ],
      classes: 'band wrap',
      id: 'reach',
      attributes: {'aria-labelledby': 't9'},
    );
  }

  Component hardware() {
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

  Component openSurface() {
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
              'Other apps can ask your second brain too — through a public '
              'HTTP API and an MCP server.',
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
              b([.text('Memory, Currents, channels, FaceTime.')]),
              .text(
                ' Search memory, list or create Currents with optional Now Brief '
                'widgets, and place FaceTime calls — all scoped to your account.',
              ),
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

  Component privacyLegacy() {
    return section(
      [
        h2([.text('Privacy')], classes: 'label', id: 't4'),
        p([
          .text('Your memory stays yours.'),
        ], classes: 'big reveal measure-tight'),
        ul([
          li([
            b([.text('Your account is the source of truth.')]),
            .text(' Your account is the source of truth.'),
          ]),
          li([
            b([.text('On-device summaries.')]),
            .text(' Summaries can stay on your Mac.'),
          ]),
          li([
            b([.text('Open source.')]),
            .text(' The boundary is open source.'),
          ]),
        ], classes: 'notes split reveal'),
      ],
      classes: 'band wrap',
      id: 'privacy',
      attributes: {'aria-labelledby': 't4'},
    );
  }

  Component pricing() {
    return section(
      [
        h2([.text('Pricing')], classes: 'label', id: 't5'),
        div([
          article([
            h3([.text('Omi with your own keys')], classes: 'label'),
            p([.text('More than 60% off')], classes: 'amount'),
            p([.text('vs managed Omi AI at ~\$35/month')], classes: 'small'),
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
            p([
              .text(
                'Checkout opens when billing is live; until then, bring your '
                'own keys or negotiate.',
              ),
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
  Component negotiate() {
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
/// signs nobody in and makes no network request.
///
/// `web/main.js` mounts the iframe as soon as the page loads. Until the app
/// is ready the frame shows a CSS still that reserves layout; the still hides
/// once the hub posts `ready`.
class HubEmbedLegacy extends StatelessComponent {
  const HubEmbedLegacy();

  @override
  Component build(BuildContext context) {
    return figure([
      div(
        [
          div(
            [
              div([
                div([], classes: 'still-orb'),
                p([], classes: 'still-greeting'),
              ], classes: 'still-greet'),
              div([
                p([], classes: 'still-line w70'),
                p([], classes: 'still-line w55'),
                p([], classes: 'still-line w45'),
              ], classes: 'still-rows'),
              p([], classes: 'still-composer'),
            ],
            classes: 'shot-still',
            attributes: {'aria-hidden': 'true'},
          ),
        ],
        classes: 'shot-frame',
        id: 'hub-frame',
        attributes: {'data-state': 'idle'},
      ),
    ], classes: 'shot');
  }
}

class _CurrentsRecreation extends StatelessComponent {
  const _CurrentsRecreation();

  @override
  Component build(BuildContext context) {
    return div([
      div([
        const OmiMark.nav(),
        div([
          span([.text('CURRENTS')], classes: 'label'),
          span([.text('4 signals · cited')], classes: 'signal-count'),
        ], classes: 'canvas-headline'),
      ], classes: 'canvas-head'),
      div([
        article([
          div([
            span([.text('YOU')], classes: 'signal-pill'),
            span([.text('NOW · FIRMWARE')], classes: 'signal-meta'),
          ], classes: 'signal-topline'),
          h3([.text('CV1 holds the line.')]),
          p([.text('Next OTA: NCS 3.4.0. Devkit-v1 waits for the PDM port.')]),
          div([
            a([.text('Review the decision')], href: portalUrl),
            span([.text('2 sources · 5h ago')]),
          ], classes: 'signal-footer'),
        ], classes: 'current-card current-card--now'),
        article([
          span([.text('CUTOVER')], classes: 'signal-meta'),
          h3([.text('Cutover has an order.')]),
          p([.text('Auth + D1 first. Billing stays put.')]),
          div([
            for (final item in ['AUTH', 'D1', 'BILLING', 'CHANNELS'])
              span([.text(item)], classes: 'route-token'),
          ], classes: 'route-map'),
        ], classes: 'current-card current-card--route'),
        article([
          span([.text('REWIND')], classes: 'signal-meta'),
          h3([.text('Quiet screens stay quiet.')]),
          p([.text('dHash drops duplicates. Check it while scrolling.')]),
          div(List.generate(16, (_) => span([])), classes: 'hash-grid'),
        ], classes: 'current-card current-card--rewind'),
        article([
          span([.text('MEMORY')], classes: 'signal-meta'),
          h3([.text('Corrections stay visible.')]),
          p([.text('The mirror keeps the before and after.')]),
          div([
            span([.text('original')]),
            span([.text('corrected')]),
          ], classes: 'evidence-slips'),
        ], classes: 'current-card current-card--memory'),
      ], classes: 'currents-grid'),
      a(
        [
          span([.text('1 more signal')], classes: 'signal-meta'),
          span([.text('The brief renderer stays allowlisted.')]),
          span([.text('Open Omi →')]),
        ],
        classes: 'more-signal',
        href: portalUrl,
      ),
    ], classes: 'currents-canvas reveal');
  }
}
