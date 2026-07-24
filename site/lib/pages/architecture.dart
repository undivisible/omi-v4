import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/omi_mark.dart';
import '../components/shell.dart';

/// One row of the model-tier table.
class _Tier {
  const _Tier(this.name, this.when, this.model);

  final String name;
  final String when;
  final String model;
}

const _tiers = [
  _Tier(
    'speed',
    'Live meeting insights, classification, quick answers',
    'inception/mercury-2',
  ),
  _Tier('balanced', 'The default — roughly 80% of traffic', 'xiaomi/mimo-v2.5'),
  _Tier('smart', 'Hard reasoning', 'xiaomi/mimo-v2.5-pro'),
  _Tier(
    'multimodal',
    'Vision and visual computer use',
    'google/gemini-3.6-flash',
  ),
  _Tier('search', 'Web-grounded answers', 'perplexity/sonar'),
];

class Architecture extends StatelessComponent {
  const Architecture({super.key});

  @override
  Component build(BuildContext context) {
    return Page(
      title: 'Omi — architecture',
      description:
          'How Omi is built: one Flutter app, an embedded Rust hub with zkr '
          'memory, a Cloudflare Worker, Telegram and Sendblue channels, '
          'FaceTime via Sendblue, model tiers, D1 memory authority, and the '
          'BLE pendant path.',
      path: '/architecture',
      rail: const [
        ('top', 'Architecture'),
        ('path', 'Request path'),
        ('tiers', 'Model tiers'),
        ('data', 'Data plane'),
        ('memory', 'Memory'),
        ('channels', 'Channels'),
        ('approval', 'Approval gate'),
        ('facetime', 'FaceTime'),
        ('pendant', 'Pendant'),
      ],
      children: [
        _hero(),
        _requestPath(),
        _modelTiers(),
        _dataPlane(),
        _memory(),
        _channels(),
        _approval(),
        _facetime(),
        _pendant(),
      ],
    );
  }

  Component _hero() {
    return section(
      [
        const OmiMark.heroSmall(),
        div([
          p([.text('Architecture')], classes: 'label rise d1'),
          h1(
            [.text('Few moving parts, on purpose.')],
            classes: 'giant rise d2',
            id: 't1',
          ),
          div([
            p([
              .text(
                'One app, one embedded runtime, one edge worker, one model '
                'gateway. Every box below exists in the repository today.',
              ),
            ], classes: 'mid rise d3'),
            div([const PrimaryActions()], classes: 'rise d4'),
          ], classes: 'hero-foot'),
        ], classes: 'hero-grid'),
      ],
      classes: 'hero wrap',
      id: 'top',
      attributes: {'aria-labelledby': 't1'},
    );
  }

  Component _requestPath() {
    return section(
      [
        h2([.text('The request path')], classes: 'label', id: 't2'),
        div([RawText(_requestPathDiagram)], classes: 'plate reveal'),
        p([
          .text('Drag the diagram sideways on a narrow screen.'),
        ], classes: 'plate-note'),
        ul([
          li([
            b([.text('The hub is linked into the app.')]),
            .text(
              ' Chat, memory, speech, the workspace scan and computer use share '
              'one process and one memory authority — no separate agent daemon.',
            ),
          ]),
          li([
            b([.text('The Worker owns the account.')]),
            .text(
              ' It verifies the Firebase ID token at the edge, then owns '
              'persistence, the memory log, currents, billing and channel '
              'delivery.',
            ),
          ]),
          li([
            b([.text('Channels share the conversation.')]),
            .text(
              ' Telegram and iMessage (Sendblue, Blooio fallback) append into '
              'the same UID-scoped ordered transport the desktop agent reads.',
            ),
          ]),
          li([
            b([.text('Realtime voice is its own path.')]),
            .text(
              ' OpenRouter is request/response only, so Gemini Live keeps a '
              'separate credential and transport.',
            ),
          ]),
        ], classes: 'notes split reveal band-gap'),
      ],
      classes: 'band wrap',
      id: 'path',
      attributes: {'aria-labelledby': 't2'},
    );
  }

  Component _modelTiers() {
    return section(
      [
        h2([.text('Model tiers')], classes: 'label', id: 't3'),
        p([
          .text('One table, three implementations.'),
        ], classes: 'big reveal measure-20'),
        div([
          table([
            caption([
              .text(
                'Defaults; every tier is overridable by environment variable, '
                'and mirrored in the hub, the Worker and its Rust parity port.',
              ),
            ], classes: 'plate-note table-caption'),
            thead([
              tr([
                th([.text('Tier')], attributes: {'scope': 'col'}),
                th([.text('When')], attributes: {'scope': 'col'}),
                th([.text('Default')], attributes: {'scope': 'col'}),
              ]),
            ]),
            tbody([
              for (final tier in _tiers)
                tr([
                  th([.text(tier.name)], attributes: {'scope': 'row'}),
                  td([.text(tier.when)]),
                  td([
                    code([.text(tier.model)]),
                  ]),
                ]),
            ]),
          ]),
        ], classes: 'table-wrap reveal'),
        ul([
          li([
            b([.text('A tier says what a request is worth paying for.')]),
            .text(
              ' Prompt intent picks it: search and vision are detected first, '
              'hard reasoning goes to the smart tier, everything else takes '
              'the default.',
            ),
          ]),
          li([
            b([.text('A capability says what a model can carry.')]),
            .text(
              ' A request states what it needs — audio in, images, audio out — '
              'and the first tier whose model declares all of it wins. If none '
              'does, the request is refused rather than sent to a model that '
              'cannot read it.',
            ),
          ]),
          li([
            b([.text('An unverified model satisfies nothing.')]),
            .text(
              ' An override naming a model the table has not checked is '
              'refused at the point of use until it declares itself, so a typo '
              'degrades to "unknown" instead of being trusted.',
            ),
          ]),
        ], classes: 'notes split reveal band-gap'),
      ],
      classes: 'band wrap',
      id: 'tiers',
      attributes: {'aria-labelledby': 't3'},
    );
  }

  Component _dataPlane() {
    return section(
      [
        h2([.text('Data plane')], classes: 'label', id: 't4'),
        p([.text('One tenant key. Yours.')], classes: 'big reveal measure-16'),
        ul([
          li([
            b([.text('D1')]),
            .text(
              ' Users, entitlements, ordered conversations, channel bindings, '
              'currents and their approval receipts — every table scoped by '
              'account.',
            ),
          ]),
          li([
            b([.text('Vectorize')]),
            .text(' The '),
            code([.text('omi-memory-claims')]),
            .text(
              ' index, embedded by Workers AI, with a per-account metadata '
              'filter on every query.',
            ),
          ]),
          li([
            b([.text('Durable Objects')]),
            .text(
              ' Four coordinators: channel delivery, assistant and speech cost '
              'admission, and rate limiting.',
            ),
          ]),
          li([
            b([.text('Memory')]),
            .text(
              ' One append-only ',
            ),
            code([.text('memory_log')]),
            .text(
              ' per account is the write authority. The read tables and '
              'Vectorize index are projections of it, so any of them can be '
              'dropped and rebuilt, and every device keeps a local zkr mirror '
              'at the sequence it last synced.',
            ),
          ]),
        ], classes: 'notes split reveal'),
      ],
      classes: 'band wrap',
      id: 'data',
      attributes: {'aria-labelledby': 't4'},
    );
  }

  Component _memory() {
    return section(
      [
        h2([.text('Memory')], classes: 'label', id: 't5'),
        p([
          .text('A log, and a view of it.'),
        ], classes: 'big reveal measure-16'),
        ul([
          li([
            b([.text('One writer.')]),
            .text(
              ' A record is not remembered until the Worker has appended it to '
              'the account ',
            ),
            code([.text('memory_log')]),
            .text(
              ' and assigned it a sequence. Devices mint records through zkr '
              'and capture evidence; they never decide ordering.',
            ),
          ]),
          li([
            b([.text('zkr on device.')]),
            .text(
              ' The hub opens a per-UID SQLite ',
            ),
            code([.text('MemoryDb')]),
            .text(
              ' keyed by Firebase UID. Pending commits sync with ',
            ),
            code([.text('POST /v1/memory/zkr-sync')]),
            .text('; the mirror advances with '),
            code([.text('GET /v1/memory/log')]),
            .text(' and '),
            code([.text('MemoryDb::apply')]),
            .text(' on desktop.'),
          ]),
          li([
            b([.text('Nothing is edited.')]),
            .text(
              ' A correction and a deletion are new records that reference the '
              'one they supersede, so an evidence chain is never rewritten and '
              'a citation stays stable for the life of the claim.',
            ),
          ]),
          li([
            b([.text('The tables are derived.')]),
            .text(
              ' Search, profile and evidence tables are folded forward from the '
              'log and use no wall clock, so replaying the log from zero '
              'produces the same rows as following it.',
            ),
          ]),
          li([
            b([.text('Recall is cited.')]),
            .text(
              ' A claim is returned only with the evidence that supports it, '
              'resolved to a source revision and its locator. A claim whose '
              'source has been deleted is dropped from the answer rather than '
              'returned uncited.',
            ),
          ]),
        ], classes: 'notes split reveal'),
      ],
      classes: 'band wrap',
      id: 'memory',
      attributes: {'aria-labelledby': 't5'},
    );
  }

  Component _channels() {
    return section(
      [
        h2([.text('Channels')], classes: 'label', id: 't8'),
        p([.text('Other inboxes, one conversation.')], classes: 'big reveal measure-16'),
        ul([
          li([
            b([.text('Telegram.')]),
            .text(
              ' Webhook-verified inbound updates link through a short-lived code '
              'in Settings. Messages append to the shared ordered conversation; '
              'outbound replies are plain text with crepus blocks stripped.',
            ),
          ]),
          li([
            b([.text('iMessage (Sendblue).')]),
            .text(
              ' Sendblue is the provider when configured; Blooio remains the '
              'fallback. The stored channel id is ',
            ),
            code([.text('blooio')]),
            .text(
              ' either way. DeliveryCoordinator serializes outbound sends per '
              'chat with lease-based retries.',
            ),
          ]),
          li([
            b([.text('Desktop picks up the thread.')]),
            .text(
              ' A channel message is an ordinary turn — the assistant can plan, '
              'propose computer use under the same approval gate, and append a '
              'reply that routes back through the channel.',
            ),
          ]),
          li([
            b([.text('Linking is required.')]),
            .text(
              ' Neither channel works until the user sends the bot a code from '
              'the app. Credentials live server-side only.',
            ),
          ]),
        ], classes: 'notes split reveal'),
      ],
      classes: 'band wrap',
      id: 'channels',
      attributes: {'aria-labelledby': 't8'},
    );
  }

  Component _approval() {
    return section(
      [
        h2([.text('The approval gate')], classes: 'label', id: 't6'),
        p([.text('Asked for is not done.')], classes: 'big reveal measure-16'),
        ul([
          li([
            b([.text('Two actions, named not aimed.')]),
            .text(
              ' The assistant can propose invoking an interface element or '
              'setting its value, addressed through the accessibility tree by '
              'exact name. No pointer, no keystrokes, no coordinates.',
            ),
          ]),
          li([
            b([.text('Bound before you see it.')]),
            .text(
              ' The named element must match exactly one element in a live '
              'observation. Zero matches and two matches fail the same way, and '
              'the proposal expires with the screen it described.',
            ),
          ]),
          li([
            b([.text('Approved once, spent once.')]),
            .text(
              ' Approval is per action. The receipt is consumed server-side '
              'before any effect, and the executor re-derives the request and '
              'refuses it if a single field has moved.',
            ),
          ]),
          li([
            b([.text('Unknown is its own answer.')]),
            .text(
              ' An action that may or may not have taken effect is recorded as '
              'unknown and is never retried automatically.',
            ),
          ]),
        ], classes: 'notes split reveal'),
      ],
      classes: 'band wrap',
      id: 'approval',
      attributes: {'aria-labelledby': 't6'},
    );
  }

  Component _facetime() {
    return section(
      [
        h2([.text('FaceTime')], classes: 'label', id: 't9'),
        p([
          .text('Ring a number, not a link.'),
        ], classes: 'big reveal measure-16'),
        ul([
          li([
            b([.text('Sendblue bridge.')]),
            .text(
              ' ',
            ),
            code([.text('POST /api/v1/facetime/calls')]),
            .text(
              ' and MCP ',
            ),
            code([.text('start_facetime_call')]),
            .text(
              ' call Sendblue\'s FaceTime start endpoint. The provider rings the '
              'handle on the recipient\'s device — there is no ',
            ),
            code([.text('facetime.apple.com')]),
            .text(' join URL.'),
          ]),
          li([
            b([.text('E.164 only.')]),
            .text(
              ' Handles must be phone numbers in E.164 form. Email FaceTime '
              'identities are refused before anything is sent upstream.',
            ),
          ]),
          li([
            b([.text('Provisioned line required.')]),
            .text(
              ' A purchased FaceTime number on the Sendblue account is required. '
              'Without one the route returns ',
            ),
            code([.text('facetime_unavailable')]),
            .text(' — a product state, not a transient fault.'),
          ]),
          li([
            b([.text('Admission and bridge.')]),
            .text(
              ' Concurrent sessions are cost-gated like managed speech. When '
              'configured, a Cloudflare Container bridge carries the realtime '
              'audio leg.',
            ),
          ]),
        ], classes: 'notes split reveal'),
      ],
      classes: 'band wrap',
      id: 'facetime',
      attributes: {'aria-labelledby': 't9'},
    );
  }

  Component _pendant() {
    return section(
      [
        h2([.text('The pendant path')], classes: 'label', id: 't7'),
        div([RawText(_pendantDiagram)], classes: 'plate reveal'),
        p([
          .text(
            'The firmware is the production nRF5340 tree. Live provider '
            'credentials and physical-device runs are still outstanding.',
          ),
        ], classes: 'plate-note'),
        p([
          a([.text('Open Omi')], classes: 'btn btn-solid', href: portalUrl),
          a([.text('Back to Omi')], classes: 'btn btn-line', href: '/'),
        ], classes: 'links band-gap'),
      ],
      classes: 'band wrap',
      id: 'pendant',
      attributes: {'aria-labelledby': 't7'},
    );
  }
}

/// The request-path plate. Authored as SVG rather than composed from boxes:
/// the arrangement is the drawing, and every label is real text a screen
/// reader and a search engine can read, backed by a `<title>`/`<desc>` pair
/// that describes the whole path in prose.
const _requestPathDiagram = '''
<svg viewBox="0 0 880 380" role="img" aria-labelledby="d1t d1d">
<title id="d1t">Omi request path</title>
<desc id="d1d">The Flutter app connects to the embedded Rust hub, which connects to the Cloudflare Worker, which connects to a Cloudflare AI Gateway fronting OpenRouter and its five model tiers: speed, balanced, smart, multimodal and search. The hub also opens a separate direct connection to the Gemini Live realtime voice API.</desc>
<text class="dg-cap" x="30" y="42">CLIENT</text>
<text class="dg-cap" x="470" y="42">EDGE</text>
<rect class="dg-box" x="30" y="70" width="180" height="84" rx="16"/>
<text class="dg-label" x="50" y="103">Flutter app</text>
<text class="dg-sub" x="50" y="122">macOS · Windows · web</text>
<text class="dg-sub" x="50" y="138">iOS · Android</text>
<rect class="dg-box dg-box-accent" x="250" y="70" width="180" height="84" rx="16"/>
<text class="dg-label" x="270" y="103">Rust hub · rinf</text>
<text class="dg-sub" x="270" y="122">chat · memory · voice</text>
<text class="dg-sub" x="270" y="138">computer use · scan</text>
<rect class="dg-box dg-box-ink" x="470" y="70" width="180" height="84" rx="16"/>
<text class="dg-label dg-label-cream" x="490" y="103">Cloudflare Worker</text>
<text class="dg-sub dg-sub-cream" x="490" y="122">auth · conversations</text>
<text class="dg-sub dg-sub-cream" x="490" y="138">currents · billing</text>
<rect class="dg-box" x="690" y="70" width="160" height="84" rx="16"/>
<text class="dg-label" x="710" y="103">AI Gateway</text>
<text class="dg-sub" x="710" y="122">caching · retries</text>
<text class="dg-sub" x="710" y="138">cost + latency</text>
<path class="dg-flow" d="M212 112h36"/>
<path class="dg-flow" d="M432 112h36"/>
<path class="dg-flow" d="M652 112h36"/>
<text class="dg-sub" x="196" y="170">rinf signals</text>
<text class="dg-sub" x="404" y="170">HTTPS + ID token</text>
<rect class="dg-box" x="250" y="200" width="180" height="64" rx="14"/>
<text class="dg-label" x="270" y="228">Gemini Live</text>
<text class="dg-sub" x="270" y="247">realtime duplex voice</text>
<path class="dg-flow dg-flow-alt" d="M340 156v42"/>
<rect class="dg-box dg-box-accent" x="470" y="200" width="380" height="64" rx="14"/>
<text class="dg-label" x="490" y="228">OpenRouter</text>
<text class="dg-sub" x="490" y="247">one endpoint · five tiers, each overridable by env</text>
<path class="dg-flow" d="M770 156v42"/>
<path class="dg-line" d="M660 266v10"/>
<path class="dg-line" d="M116 276h648"/>
<path class="dg-line" d="M116 276v12M278 276v12M440 276v12M602 276v12M764 276v12"/>
<rect class="dg-box" x="41" y="288" width="150" height="62" rx="14"/>
<text class="dg-label" x="57" y="314">speed</text>
<text class="dg-sub" x="57" y="333">inception/mercury-2</text>
<rect class="dg-box" x="203" y="288" width="150" height="62" rx="14"/>
<text class="dg-label" x="219" y="314">balanced</text>
<text class="dg-sub" x="219" y="333">xiaomi/mimo-v2.5</text>
<rect class="dg-box" x="365" y="288" width="150" height="62" rx="14"/>
<text class="dg-label" x="381" y="314">smart</text>
<text class="dg-sub" x="381" y="333">xiaomi/mimo-v2.5-pro</text>
<rect class="dg-box" x="527" y="288" width="150" height="62" rx="14"/>
<text class="dg-label" x="543" y="314">multimodal</text>
<text class="dg-sub" x="543" y="333">google/gemini-3.6-flash</text>
<rect class="dg-box" x="689" y="288" width="150" height="62" rx="14"/>
<text class="dg-label" x="705" y="314">search</text>
<text class="dg-sub" x="705" y="333">perplexity/sonar</text>
</svg>''';

const _pendantDiagram = '''
<svg viewBox="0 0 880 150" role="img" aria-labelledby="d2t d2d">
<title id="d2t">Pendant to memory</title>
<desc id="d2d">The pendant streams audio over Bluetooth LE to the mobile app, which relays bounded audio chunks to the Rust hub, which captures final transcript segments into evidence-backed memory.</desc>
<circle cx="70" cy="70" r="34" fill="#0d0d0c"/>
<circle cx="70" cy="70" r="12" fill="#fffcec"/>
<text class="dg-sub" x="34" y="128">Omi pendant</text>
<path class="dg-flow" d="M120 70h60"/>
<text class="dg-sub" x="128" y="58">BLE</text>
<rect class="dg-box" x="196" y="38" width="170" height="64" rx="14"/>
<text class="dg-label" x="214" y="66">Mobile app</text>
<text class="dg-sub" x="214" y="85">pairing · relay · health</text>
<path class="dg-flow" d="M370 70h50"/>
<text class="dg-sub" x="366" y="58">audio chunks</text>
<rect class="dg-box dg-box-accent" x="436" y="38" width="170" height="64" rx="14"/>
<text class="dg-label" x="454" y="66">Rust hub</text>
<text class="dg-sub" x="454" y="85">transcription · capture</text>
<path class="dg-flow" d="M610 70h50"/>
<text class="dg-sub" x="600" y="58">final segments</text>
<rect class="dg-box dg-box-ink" x="676" y="38" width="174" height="64" rx="14"/>
<text class="dg-label dg-label-cream" x="694" y="66">Evidenced memory</text>
<text class="dg-sub dg-sub-cream" x="694" y="85">claims + citations</text>
</svg>''';
