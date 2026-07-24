/// The entrypoint for pre-rendering.
///
/// There is deliberately no `main.client.dart` beside this file. Jaspr injects
/// its client bundle into every generated page whenever a client entrypoint
/// exists, so removing it is what makes the built pages carry no Dart
/// JavaScript at all. See README.md for the measurements.
library;

import 'package:jaspr/dom.dart';
import 'package:jaspr/server.dart';

import 'app.dart';
import 'main.server.options.dart';

void main() {
  Jaspr.initializeApp(options: defaultServerOptions);

  runApp(
    Document(
      lang: 'en',
      // Per-page titles, descriptions and the rest of the head are supplied by
      // each page through `Document.head`; this is only the shell.
      title: 'Omi',
      head: [
        // The two enhancement modules, both additive. `main.js` marks the nav,
        // spies the section rail, reveals sections on scroll and swaps the hub
        // still for the live app on click. `mark.js` drives the mark's orbit,
        // scatter and pulse. If either fails to load the page is still complete
        // and every link still works.
        script(src: '/main.js', defer: true),
        script(src: '/mark.js', defer: true),
      ],
      body: const App(),
    ),
  );
}
