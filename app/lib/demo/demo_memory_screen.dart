import 'package:flutter/material.dart';

import 'demo_seed.dart';

/// The claims the demo's currents cite, listed so a citation can be followed.
///
/// This screen exists because "evidence-backed" is a claim the product makes
/// about itself, and a tour that asserts it without letting the visitor check
/// is no better than a bullet point. Every `sourceId` cited by a seeded
/// current appears here; nothing cited points outside this list.
class DemoMemoryScreen extends StatelessWidget {
  const DemoMemoryScreen({this.highlight, super.key});

  /// A source id to scroll into view and mark, when the tour arrived here
  /// from a specific citation.
  final String? highlight;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xfff4f2ea) : const Color(0xff171716);
    final muted = dark ? const Color(0xffa6a49c) : const Color(0xff706e68);
    final paper = dark ? const Color(0xff171716) : const Color(0xfff7f6f1);
    final hairline = dark ? const Color(0x1ffffcec) : const Color(0x14171716);
    final items = demoMemoryItems();
    final narrow = MediaQuery.sizeOf(context).width < 560;
    return Scaffold(
      backgroundColor: paper,
      appBar: AppBar(
        backgroundColor: paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: ink,
        title: Text(
          'Memory',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: ink,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.symmetric(
            horizontal: narrow ? 16 : 28,
            vertical: 12,
          ),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Every current on the hub cites its sources by id. These '
                      'are those sources. Seeded, like the rest of the demo — '
                      'but the citations resolve, which is the part worth '
                      'checking.',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.55,
                        color: muted,
                      ),
                    ),
                    const SizedBox(height: 18),
                    for (final item in items)
                      Container(
                        key: ValueKey('demo_memory_${item.id}'),
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: item.id == highlight ? muted : hairline,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.id,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.3,
                                color: muted,
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              item.body,
                              style: TextStyle(
                                fontSize: 13.5,
                                height: 1.5,
                                color: ink,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
