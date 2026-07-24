import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../brand.dart';
import 'omi_mark.dart';

/// Where things live once the domains are split. The site is served from
/// omi.tsc.hk; the API, its reference and the portal from api.omi.tsc.hk.
/// Kept in one place so the split moves in one edit.
const apiHost = 'https://api.omi.tsc.hk';
const portalUrl = '$apiHost/portal';
const apiKeysUrl = '$apiHost/portal#api-keys';

/// The API reference is served from the API's own host, alongside the contract
/// it documents, so "Documentation" leaves omi.tsc.hk the way the portal does.
const apiDocsUrl = '$apiHost/docs/api';

/// Where the desktop and mobile builds are downloaded.
const downloadUrl = 'https://omi.me/download';

/// The nine soft blurred lights behind the page.
///
/// Ported from `OnboardingBackdrop` in
/// `app/lib/features/onboarding/backdrop.dart`, which is the motion this is
/// meant to read as: nine coloured radial blobs pinned just outside each edge
/// of the viewport, each tracing a slow Lissajous figure on a shared 14-second
/// loop, the whole field blurred and then masked by an oval that thins the
/// centre and cuts the outside off. The colours and the geometry are the
/// backdrop's own; only the medium changes.
///
/// Each light is two elements because the two axes run at different rates in
/// the original (`cos(phase)` against `sin(phase * .83)`), and one element can
/// only carry one transform animation. `--x`/`--y` are the backdrop's
/// `Alignment` coordinates, where 1 is half the viewport.
class GlowField extends StatelessComponent {
  const GlowField({super.key});

  /// `(x, y, colour)`, transcribed from `_OnboardingEdgeGradientState.build`.
  static const lights = <(double, double, String)>[
    (-1.25, -1.2, '#f25e6b'),
    (-0.25, -1.25, '#f2c2ac'),
    (0.35, -1.25, '#ffd0b8'),
    (1.2, -1.05, '#96c4ff'),
    (1.25, 0.05, '#b9d6ff'),
    (1.2, 1.15, '#d3e081'),
    (0.05, 1.25, '#f4d69f'),
    (-0.75, 1.2, '#f2c2ac'),
    (-1.25, 0.45, '#ff9a91'),
  ];

  @override
  Component build(BuildContext context) {
    final buffer = StringBuffer('<div class="field" aria-hidden="true">');
    for (var index = 0; index < lights.length; index++) {
      final (x, y, colour) = lights[index];
      buffer.write(
        '<i style="--x:$x;--y:$y;--i:$index"><b style="--c:$colour"></b></i>',
      );
    }
    buffer.write('</div>');
    return RawText(buffer.toString());
  }
}

/// The three things a reader can do, carried by the page itself rather than by
/// a bar across the top of it.
class PrimaryActions extends StatelessComponent {
  const PrimaryActions({super.key});

  @override
  Component build(BuildContext context) {
    return div([
      a([.text('Open Omi')], classes: 'btn btn-solid', href: portalUrl),
      a([.text('Documentation')], classes: 'btn btn-line', href: apiDocsUrl),
      a([.text('API login')], classes: 'btn btn-line', href: apiKeysUrl),
    ], classes: 'links');
  }
}

/// The fixed contents rail down the left edge: the mark at the top, then the
/// page's own structure set in the accent face, doubling as a scroll position.
/// Desktop only — below 1200px the sections' own labels carry it, and the
/// stylesheet hides it.
class SectionRail extends StatelessComponent {
  const SectionRail(this.sections, {super.key});

  /// Anchor id to label, in page order.
  final List<(String, String)> sections;

  @override
  Component build(BuildContext context) {
    return nav(
      [
        a(
          [const OmiMark.rail()],
          classes: 'rail-mark',
          href: '/',
          attributes: {'aria-label': 'Omi home'},
        ),
        ol([
          for (final (anchor, label) in sections)
            li([
              a([.text(label)], href: '#$anchor'),
            ]),
        ]),
      ],
      classes: 'rail',
      attributes: {'aria-label': 'Sections'},
    );
  }
}

/// One column of the footer: a heading and its links.
class _FooterColumn extends StatelessComponent {
  const _FooterColumn(this.heading, this.links);

  final String heading;
  final List<(String, String)> links;

  @override
  Component build(BuildContext context) {
    return nav(
      [
        h2([.text(heading)], classes: 'label'),
        ul([
          for (final (label, href) in links)
            li([
              a([.text(label)], href: href),
            ]),
        ]),
      ],
      classes: 'foot-col',
      attributes: {'aria-label': heading},
    );
  }
}

class SiteFooter extends StatelessComponent {
  const SiteFooter({super.key});

  /// The columns are the ones omi.me publishes, pointing at the same places.
  static const _company = [
    ('Careers', 'https://www.omi.me/pages/careers'),
    ('Invest', 'https://omi.me/invest'),
    ('Privacy', 'https://www.omi.me/pages/privacy'),
    ('Events', 'https://www.omi.me/blogs/events/'),
    ('Manifesto', 'https://omi.me/manifesto'),
    ('Compliance', 'https://omi.me/trust'),
  ];

  static const _products = [
    ('Omi', 'https://www.omi.me/pages/product'),
    ('Omi Glass', 'https://omi.me/glass'),
    ('Omi Enterprise', 'https://omi.me/enterprise'),
    ('Wrist Band', 'https://www.omi.me/products/omi-watch-band'),
    ('Omi Charger', 'https://www.omi.me/products/omi-wireless-charger'),
    ('Download', downloadUrl),
  ];

  /// The first four are this build's own pages; the rest are Omi's.
  static const _resources = [
    ('Architecture', '/architecture'),
    ('API reference', '/docs/api'),
    ('Open Omi', portalUrl),
    ('API login', apiKeysUrl),
    ('Help Center', 'https://help.omi.me'),
    ('Status', 'https://status.omi.me'),
    ('App Store', 'https://h.omi.me/apps'),
    ('GitHub', 'https://github.com/BasedHardware/omi'),
    ('Community', 'https://discord.omi.me/'),
  ];

  @override
  Component build(BuildContext context) {
    return footer([
      div([
        div([
          p([const OmiMark.footer(), .text(' thought to action.')]),
          p([
            .text('Based Hardware Inc.'),
            br(),
            .text('San Francisco'),
            br(),
            a([.text('help@omi.me')], href: 'mailto:help@omi.me'),
          ], classes: 'small'),
        ], classes: 'foot-id'),
        const _FooterColumn('Company', _company),
        const _FooterColumn('Products', _products),
        const _FooterColumn('Resources', _resources),
      ], classes: 'foot'),
      p([
        .text('© 2026 Based Hardware. All rights reserved.'),
      ], classes: 'foot-rule small'),
    ], classes: 'wrap');
  }
}

/// One page of the site: its head, the skip link, the glow field, a `<main>`
/// landmark holding the page's own content, and the footer. Every page is
/// built from this, so the landmarks and the heading order are structural
/// rather than remembered. There is no bar across the top: the rail carries
/// the mark and the page's structure, and each page carries its own actions.
class Page extends StatelessComponent {
  const Page({
    required this.title,
    required this.description,
    required this.path,
    required this.children,
    this.rail = const [],
    super.key,
  });

  final String title;
  final String description;
  final String path;
  final List<Component> children;
  final List<(String, String)> rail;

  @override
  Component build(BuildContext context) {
    const canonicalHost = 'https://omi.tsc.hk';

    return Component.fragment([
      Document.head(
        title: title,
        meta: {'description': description},
        children: [
          link(rel: 'icon', href: faviconDataUri()),
          link(rel: 'canonical', href: '$canonicalHost$path'),
          // The two faces the first screen sets are fetched alongside the
          // stylesheet rather than after it, so the hero never reflows.
          link(
            rel: 'preload',
            href: '/inter-latin-variable.woff2',
            attributes: {'as': 'font', 'type': 'font/woff2', 'crossorigin': ''},
          ),
          link(
            rel: 'preload',
            href: '/geist-pixel-square.woff2',
            attributes: {'as': 'font', 'type': 'font/woff2', 'crossorigin': ''},
          ),
          link(rel: 'stylesheet', href: '/styles.css'),
          meta(attributes: {'name': 'theme-color', 'content': inkColor}),
          meta(attributes: {'property': 'og:title', 'content': title}),
          meta(
            attributes: {'property': 'og:description', 'content': description},
          ),
          meta(attributes: {'property': 'og:type', 'content': 'website'}),
          meta(
            attributes: {
              'property': 'og:url',
              'content': '$canonicalHost$path',
            },
          ),
        ],
      ),
      a([.text('Skip to content')], classes: 'skip-link', href: '#main'),
      const GlowField(),
      main_([if (rail.isNotEmpty) SectionRail(rail), ...children], id: 'main'),
      const SiteFooter(),
    ]);
  }
}
