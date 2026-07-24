import 'dart:async';

import 'package:flutter/material.dart';

import '../memory/memory.dart';

// The paper palette the rest of the companion shell paints in, kept local so
// this screen stands alone without reaching into the shell's private colours.
const _paper = Color(0xfff7f6f1);
const _surface = Color(0xfffffefa);
const _ink = Color(0xff171716);
const _inkSoft = Color(0xff706e68);
const _hairline = Color(0x14171716);
const _inkSheet = Color(0xff1c1c1a);
const _cream = Color(0xfffffcec);
const _teal = Color(0xff2f9d8a);
const _coral = Color(0xffd97757);

bool _dark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _pageInk(BuildContext context) => _dark(context) ? _cream : _ink;

Color _pageInkSoft(BuildContext context) =>
    _dark(context) ? const Color(0xffa6a49c) : _inkSoft;

Color _pageSurface(BuildContext context) =>
    _dark(context) ? const Color(0xff232320) : _surface;

Color _pageHairline(BuildContext context) =>
    _dark(context) ? const Color(0x1ffffcec) : _hairline;

/// The mobile memory surface: one page where the bottom field both searches
/// and adds. Submit / Enter searches; the trailing + button remembers.
///
/// Both halves talk to the same [MemoryClient] the desktop uses — search hits
/// `/v1/memory/retrieve`, remember hits `/v1/memories`.
class MobileMemoryScreen extends StatefulWidget {
  const MobileMemoryScreen({
    required this.memory,
    this.embedded = false,
    super.key,
  });

  final MemoryClient memory;

  /// When true, omit the AppBar so the screen can sit inside a PageView.
  final bool embedded;

  @override
  State<MobileMemoryScreen> createState() => _MobileMemoryScreenState();
}

class _MobileMemoryScreenState extends State<MobileMemoryScreen> {
  final _field = TextEditingController();
  final _focus = FocusNode();

  RetrievalPack? _results;
  String? _error;
  String? _done;
  bool _busy = false;

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _field.text.trim();
    if (query.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      final pack = await widget.memory.retrieve(query: query);
      if (!mounted) return;
      setState(() {
        _results = pack;
        _busy = false;
      });
    } on MemoryClientException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _results = null;
        _busy = false;
      });
    }
  }

  Future<void> _add() async {
    final content = _field.text.trim();
    if (content.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      await widget.memory.createMemory(content);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = 'Saved. Omi will remember this.';
        _field.clear();
      });
    } on MemoryClientException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = _dark(context);
    final body = Column(
      children: [
        Expanded(
          child: ListView(
            key: const Key('mobile_memory_list'),
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
            children: [
              Text(
                'Memory',
                style: TextStyle(
                  fontSize: widget.embedded ? 28 : 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: widget.embedded ? -0.6 : 0,
                  color: _pageInk(context),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Search what Omi knows, or add something new.',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.35,
                  color: _pageInkSoft(context),
                ),
              ),
              const SizedBox(height: 18),
              ..._resultsSection(context),
            ],
          ),
        ),
        _composer(context),
      ],
    );
    if (widget.embedded) {
      return ColoredBox(
        key: const Key('mobile_memory_screen'),
        color: dark ? _inkSheet : _paper,
        child: SafeArea(top: false, child: body),
      );
    }
    return Scaffold(
      key: const Key('mobile_memory_screen'),
      backgroundColor: dark ? _inkSheet : _paper,
      appBar: AppBar(
        backgroundColor: dark ? _inkSheet : _paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: _pageInk(context),
        title: const Text(
          'Memory',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _composer(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Material(
      color: _pageSurface(context),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: _pageHairline(context))),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 10, 10, 10 + bottom),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('memory_search_field'),
                  controller: _field,
                  focusNode: _focus,
                  textInputAction: TextInputAction.search,
                  textCapitalization: TextCapitalization.sentences,
                  onSubmitted: (_) => unawaited(_search()),
                  enabled: !_busy,
                  style: TextStyle(color: _pageInk(context), fontSize: 15),
                  decoration: InputDecoration(
                    hintText: 'search or add a memory',
                    hintStyle: TextStyle(color: _pageInkSoft(context)),
                    filled: true,
                    fillColor: _dark(context) ? _inkSheet : _paper,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(999),
                      borderSide: BorderSide(color: _pageHairline(context)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(999),
                      borderSide: BorderSide(color: _pageHairline(context)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(999),
                      borderSide: BorderSide(
                        color: _pageInk(context).withValues(alpha: .35),
                      ),
                    ),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: _pageInk(context),
                shape: const CircleBorder(),
                child: InkWell(
                  key: const Key('memory_create_submit'),
                  customBorder: const CircleBorder(),
                  onTap: _busy ? null : () => unawaited(_add()),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Center(
                      child: _busy
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _dark(context) ? _ink : _cream,
                              ),
                            )
                          : Icon(
                              Icons.add_rounded,
                              color: _dark(context) ? _ink : _cream,
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _resultsSection(BuildContext context) {
    if (_done != null) {
      return [
        Text(
          _done!,
          key: const Key('memory_create_done'),
          style: const TextStyle(color: _teal, fontSize: 13, height: 1.4),
        ),
      ];
    }
    if (_error != null) {
      return [
        Text(
          _error!,
          key: const Key('memory_search_error'),
          style: const TextStyle(color: _coral, fontSize: 13, height: 1.4),
        ),
      ];
    }
    final pack = _results;
    if (pack == null) {
      return [
        Text(
          'Type below and press return to search, or tap + to remember.',
          key: const Key('memory_search_empty'),
          style: TextStyle(
            color: _pageInkSoft(context),
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ];
    }
    if (pack.items.isEmpty) {
      return [
        Text(
          'No memories matched "${pack.query}". Tap + to add it.',
          style: TextStyle(
            color: _pageInkSoft(context),
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ];
    }
    return [
      for (final item in pack.items) ...[
        DecoratedBox(
          decoration: BoxDecoration(
            color: _pageSurface(context),
            border: Border.all(color: _pageHairline(context)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.excerpt,
                  style: TextStyle(
                    color: _pageInk(context),
                    fontSize: 15,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${item.memory.kind.name.toUpperCase()} · '
                  '${(item.relevanceBasisPoints / 100).round()}% match',
                  style: TextStyle(
                    color: _pageInkSoft(context),
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    ];
  }
}
