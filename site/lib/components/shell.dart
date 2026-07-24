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

/// The three soft blurred lights behind the page. Purely decorative, fixed
/// behind everything, and held still under `prefers-reduced-motion`.
class GlowField extends StatelessComponent {
  const GlowField({super.key});

  @override
  Component build(BuildContext context) => RawText(
    '<div class="field" aria-hidden="true"><i></i><i></i><i></i></div>',
  );
}

/// Primary navigation: three buttons in the centre of the bar, and nothing in
/// the top right. `web/main.js` adds `.stuck` once the page has scrolled,
/// which is what gives the bar its translucent material.
class SiteNav extends StatelessComponent {
  const SiteNav({required this.current, super.key});

  /// The path of the page being rendered, used to mark the current link.
  final String current;

  @override
  Component build(BuildContext context) {
    return header(
      [
        a(
          [const OmiMark.nav(), .text(' Omi')],
          classes: 'brand',
          href: '/',
          attributes: {'aria-label': 'Omi home'},
        ),
        nav(
          [
            a([.text('Open Omi')], classes: 'cta', href: portalUrl),
            a(
              [.text('Documentation')],
              href: '/architecture',
              attributes: current == '/architecture'
                  ? {'aria-current': 'page'}
                  : const {},
            ),
            a([.text('API login')], href: apiKeysUrl),
          ],
          classes: 'nav-links',
          id: 'navLinks',
          attributes: {'aria-label': 'Primary'},
        ),
      ],
      classes: 'nav',
      id: 'nav',
    );
  }
}

/// The fixed contents rail down the left edge: the page's own structure set in
/// the accent face, doubling as a scroll position. Desktop only — below
/// 1200px the sections' own labels carry it, and the stylesheet hides it.
class SectionRail extends StatelessComponent {
  const SectionRail(this.sections, {super.key});

  /// Anchor id to label, in page order.
  final List<(String, String)> sections;

  @override
  Component build(BuildContext context) {
    return nav(
      [
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

class SiteFooter extends StatelessComponent {
  const SiteFooter({super.key});

  @override
  Component build(BuildContext context) {
    return footer([
      div([
        p([const OmiMark.footer(), .text(' Open source, private by design.')]),
        nav(
          [
            a([.text('What it does')], href: '/#what'),
            a([.text('API')], href: '/#api'),
            a([.text('Architecture')], href: '/architecture'),
            a([.text('API reference')], href: '/docs/api'),
            a([.text('Open Omi')], href: portalUrl),
          ],
          attributes: {'aria-label': 'Footer'},
        ),
      ], classes: 'foot'),
    ], classes: 'wrap');
  }
}

/// One page of the site: its head, the skip link, the glow field, the nav, a
/// `<main>` landmark holding the page's own content, and the footer. Every
/// page is built from this, so the landmarks and the heading order are
/// structural rather than remembered.
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
      SiteNav(current: path),
      main_([if (rail.isNotEmpty) SectionRail(rail), ...children], id: 'main'),
      const SiteFooter(),
    ]);
  }
}
