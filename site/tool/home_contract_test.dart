import 'dart:io';

void expectContains(String source, String expected) {
  if (!source.contains(expected)) {
    stderr.writeln('Expected home.dart to contain: $expected');
    exitCode = 1;
  }
}

void main() {
  final source = File('lib/pages/home.dart').readAsStringSync();

  // A first-time visitor must understand the product before seeing a demo.
  expectContains(source, "title: 'Omi — private memory that stays useful'");
  expectContains(
    source,
    'children: [hubHeroLegacy(), hubLegacy(), makeItYoursLegacy()]',
  );
  expectContains(source, 'Life moves fast. Keep the thread.');
  expectContains(source, 'A private memory for the things you choose to keep');

  // The embedded Hub is illustrative, not an account surface.
  expectContains(source, 'TRY THE DEMO · SAMPLE DATA');
  expectContains(
    source,
    'Explore a guided example before you connect anything.',
  );
  expectContains(source, 'Try the sample Hub ↓');

  // Visitors can enter the actual product without being forced through the demo.
  expectContains(source, 'Open your Omi');
}
