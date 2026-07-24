import 'package:jaspr/jaspr.dart';
import 'package:jaspr_router/jaspr_router.dart';

import 'pages/api_docs.dart';
import 'pages/architecture.dart';
import 'pages/home.dart';

/// The site's routes.
///
/// Multi-page routing: this component is built only on the server during
/// pre-rendering, and each route becomes a static HTML file. No component on
/// any of these pages is annotated `@client`, so no page carries a Dart
/// bundle — the only JavaScript that ships is the two hand-written
/// progressive-enhancement modules in `web/`.
class App extends StatelessComponent {
  const App({super.key});

  @override
  Component build(BuildContext context) {
    return Router(
      routes: [
        Route(path: '/', builder: (context, state) => const Home()),
        Route(
          path: '/architecture',
          builder: (context, state) => const Architecture(),
        ),
        Route(path: '/docs/api', builder: (context, state) => const ApiDocs()),
      ],
    );
  }
}
