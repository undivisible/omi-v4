import 'dart:async';

import 'package:flutter/material.dart';

import '../memory/memory.dart';
import '../ui/omi_orb.dart';

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

const _floatingBarHeight = 52.0;
const _searchDebounceDelay = Duration(milliseconds: 300);

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
/// and adds. Typing searches after a short debounce; the trailing + remembers.
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
  bool _searchBusy = false;
  bool _addBusy = false;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _field.addListener(_scheduleSearch);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _field.removeListener(_scheduleSearch);
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _scheduleSearch() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(_searchDebounceDelay, () => unawaited(_search()));
  }

  Future<void> _search() async {
    final query = _field.text.trim();
    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _results = null;
        _searchBusy = false;
      });
      return;
    }
    if (_searchBusy) return;
    setState(() {
      _searchBusy = true;
      _error = null;
      _done = null;
    });
    try {
      final pack = await widget.memory.retrieve(query: query);
      if (!mounted) return;
      setState(() {
        _results = pack;
        _searchBusy = false;
      });
    } on MemoryClientException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _results = null;
        _searchBusy = false;
      });
    }
  }

  Future<void> _add() async {
    final content = _field.text.trim();
    if (content.isEmpty || _addBusy) return;
    _searchDebounce?.cancel();
    setState(() {
      _addBusy = true;
      _error = null;
      _done = null;
    });
    try {
      await widget.memory.createMemory(content);
      if (!mounted) return;
      setState(() {
        _addBusy = false;
        _done = 'Saved. Omi will remember this.';
        _searchDebounce?.cancel();
        _field.clear();
        _results = null;
      });
    } on MemoryClientException catch (error) {
      if (!mounted) return;
      setState(() {
        _addBusy = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = _dark(context);
    final listBottomInset = _floatingBarHeight + 28;
    final body = Stack(
      children: [
        ListView(
          key: const Key('mobile_memory_list'),
          padding: EdgeInsets.fromLTRB(
            18,
            widget.embedded ? 56 : 12,
            18,
            listBottomInset,
          ),
          children: _resultsSection(context),
        ),
        Positioned(
          left: 18,
          right: 18,
          bottom: widget.embedded
              ? 0
              : 12 + MediaQuery.paddingOf(context).bottom,
          child: _floatingComposer(context),
        ),
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
      ),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _floatingComposer(BuildContext context) {
    final dark = _dark(context);
    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        key: const Key('memory_floating_bar'),
        decoration: BoxDecoration(
          color: _pageSurface(context),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: _pageHairline(context)),
          boxShadow: [
            BoxShadow(
              color: dark
                  ? Colors.black.withValues(alpha: .35)
                  : _ink.withValues(alpha: .08),
              offset: const Offset(0, 4),
              blurRadius: 16,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('memory_search_field'),
                  controller: _field,
                  focusNode: _focus,
                  textInputAction: TextInputAction.search,
                  textCapitalization: TextCapitalization.sentences,
                  onSubmitted: (_) {
                    _searchDebounce?.cancel();
                    unawaited(_search());
                  },
                  enabled: !_addBusy,
                  style: TextStyle(color: _pageInk(context), fontSize: 15),
                  decoration: const InputDecoration(
                    filled: true,
                    fillColor: Colors.transparent,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              Container(width: 1, height: 28, color: _pageHairline(context)),
              Material(
                color: _pageInk(context),
                shape: const CircleBorder(),
                child: InkWell(
                  key: const Key('memory_create_submit'),
                  customBorder: const CircleBorder(),
                  onTap: _addBusy ? null : () => unawaited(_add()),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: _addBusy
                          ? OmiActivityOrb.loading(
                              size: 18,
                              color: dark ? _ink : _cream,
                            )
                          : Icon(
                              Icons.add_rounded,
                              color: dark ? _ink : _cream,
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
      return const [];
    }
    if (pack.items.isEmpty) {
      return [
        Text(
          'No memories matched "${pack.query}". Tap + to add it.',
          key: const Key('memory_search_empty'),
          style: TextStyle(
            color: _pageInkSoft(context),
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ];
    }
    return [
      for (var index = 0; index < pack.items.length; index++) ...[
        DecoratedBox(
          key: Key('memory_result_$index'),
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
                  pack.items[index].excerpt,
                  style: TextStyle(
                    color: _pageInk(context),
                    fontSize: 15,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${pack.items[index].memory.kind.name.toUpperCase()} · '
                  '${(pack.items[index].relevanceBasisPoints / 100).round()}% match',
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
