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
          'How Omi is built: one Flutter app, an embedded Rust hub, a '
          'Cloudflare Worker, an AI Gateway in front of OpenRouter model '
          'tiers, D1, Vectorize, Durable Objects, and the BLE pendant path.',
      path: '/architecture',
      rail: const [
        ('top', 'Architecture'),
        ('path', 'Request path'),
        ('tiers', 'Model tiers'),
        ('data', 'Data plane'),
        ('pendant', 'Pendant'),
      ],
      children: [
        _hero(),
        _requestPath(),
        _modelTiers(),
        _dataPlane(),
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
              'persistence, currents, billing and channel delivery.',
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
              ' The source of truth is a local database in the hub, at a path '
              'keyed by a hash of your account id.',
            ),
          ]),
        ], classes: 'notes split reveal'),
      ],
      classes: 'band wrap',
      id: 'data',
      attributes: {'aria-labelledby': 't4'},
    );
  }

  Component _pendant() {
    return section(
      [
        h2([.text('The pendant path')], classes: 'label', id: 't5'),
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
      attributes: {'aria-labelledby': 't5'},
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
