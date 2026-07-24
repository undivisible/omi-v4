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

bool _dark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _pageInk(BuildContext context) => _dark(context) ? _cream : _ink;

Color _pageInkSoft(BuildContext context) =>
    _dark(context) ? const Color(0xffa6a49c) : _inkSoft;

Color _pageSurface(BuildContext context) =>
    _dark(context) ? const Color(0xff232320) : _surface;

Color _pageHairline(BuildContext context) =>
    _dark(context) ? const Color(0x1ffffcec) : _hairline;

/// The mobile memory surface: search cited memories and remember new ones.
///
/// Both halves talk to the same [MemoryClient] the desktop uses — search hits
/// `/v1/memory/retrieve`, remember hits `/v1/memories`. Every failure the client
/// can raise (no backend, signed out, offline, a malformed reply) surfaces as an
/// explained line rather than an empty screen, which is how the rest of the
/// companion degrades when there is nothing to reach.
class MobileMemoryScreen extends StatefulWidget {
  const MobileMemoryScreen({required this.memory, super.key});

  final MemoryClient memory;

  @override
  State<MobileMemoryScreen> createState() => _MobileMemoryScreenState();
}

class _MobileMemoryScreenState extends State<MobileMemoryScreen> {
  final _searchController = TextEditingController();
  final _createController = TextEditingController();

  RetrievalPack? _results;
  String? _searchError;
  bool _searching = false;

  String? _createError;
  String? _createDone;
  bool _creating = false;

  @override
  void dispose() {
    _searchController.dispose();
    _createController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final pack = await widget.memory.retrieve(query: query);
      if (!mounted) return;
      setState(() {
        _results = pack;
        _searching = false;
      });
    } on MemoryClientException catch (error) {
      if (!mounted) return;
      setState(() {
        _searchError = error.message;
        _results = null;
        _searching = false;
      });
    }
  }

  Future<void> _create() async {
    final content = _createController.text.trim();
    if (content.isEmpty || _creating) return;
    setState(() {
      _creating = true;
      _createError = null;
      _createDone = null;
    });
    try {
      await widget.memory.createMemory(content);
      if (!mounted) return;
      setState(() {
        _creating = false;
        _createDone = 'Saved. Omi will remember this.';
        _createController.clear();
      });
    } on MemoryClientException catch (error) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _createError = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = _dark(context);
    final narrow = MediaQuery.sizeOf(context).width < 560;
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
      body: SafeArea(
        top: false,
        child: ListView(
          key: const Key('mobile_memory_list'),
          padding: EdgeInsets.fromLTRB(
            narrow ? 16 : 28,
            12,
            narrow ? 16 : 28,
            24,
          ),
          children: [
            _label(context, 'REMEMBER'),
            const SizedBox(height: 8),
            _createCard(context),
            const SizedBox(height: 22),
            _label(context, 'SEARCH'),
            const SizedBox(height: 8),
            _searchCard(context),
            const SizedBox(height: 16),
            ..._resultsSection(context),
          ],
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.43,
        color: _pageInkSoft(context),
      ),
    ),
  );

  Widget _card(BuildContext context, {required Widget child}) => DecoratedBox(
    decoration: BoxDecoration(
      color: _pageSurface(context),
      border: Border.all(color: _pageHairline(context)),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );

  Widget _createCard(BuildContext context) => _card(
    context,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('memory_create_field'),
          controller: _createController,
          minLines: 2,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          style: TextStyle(
            color: _pageInk(context),
            fontSize: 15,
            height: 1.35,
          ),
          decoration: InputDecoration(
            hintText: 'Something you want Omi to remember…',
            hintStyle: TextStyle(color: _pageInkSoft(context)),
            border: InputBorder.none,
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (_createDone != null)
              Expanded(
                child: Text(
                  _createDone!,
                  key: const Key('memory_create_done'),
                  style: const TextStyle(
                    color: Color(0xff2f9d8a),
                    fontSize: 13,
                  ),
                ),
              )
            else if (_createError != null)
              Expanded(
                child: Text(
                  _createError!,
                  key: const Key('memory_create_error'),
                  style: const TextStyle(
                    color: Color(0xffd97757),
                    fontSize: 13,
                  ),
                ),
              )
            else
              const Spacer(),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('memory_create_submit'),
              onPressed: _creating ? null : () => unawaited(_create()),
              child: _creating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Remember'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _searchCard(BuildContext context) => _card(
    context,
    child: Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key('memory_search_field'),
            controller: _searchController,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => unawaited(_search()),
            style: TextStyle(color: _pageInk(context), fontSize: 15),
            decoration: InputDecoration(
              hintText: 'Search your memories…',
              hintStyle: TextStyle(color: _pageInkSoft(context)),
              border: InputBorder.none,
              isDense: true,
            ),
          ),
        ),
        IconButton(
          key: const Key('memory_search_submit'),
          onPressed: _searching ? null : () => unawaited(_search()),
          icon: _searching
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(Icons.search_rounded, color: _pageInkSoft(context)),
        ),
      ],
    ),
  );

  List<Widget> _resultsSection(BuildContext context) {
    if (_searchError != null) {
      return [
        Text(
          _searchError!,
          key: const Key('memory_search_error'),
          style: TextStyle(
            color: _pageInkSoft(context),
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ];
    }
    final pack = _results;
    if (pack == null) return const [];
    if (pack.items.isEmpty) {
      return [
        Text(
          'No memories matched "${pack.query}".',
          key: const Key('memory_search_empty'),
          style: TextStyle(
            color: _pageInkSoft(context),
            fontSize: 13,
            height: 1.4,
          ),
        ),
        if (pack.gaps.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'Gaps: ${pack.gaps.join(', ')}',
            style: TextStyle(color: _pageInkSoft(context), fontSize: 12),
          ),
        ],
      ];
    }
    return [
      for (var i = 0; i < pack.items.length; i += 1) ...[
        _resultTile(context, i, pack.items[i]),
        const SizedBox(height: 8),
      ],
    ];
  }

  Widget _resultTile(BuildContext context, int index, RetrievalItem item) =>
      DecoratedBox(
        key: Key('memory_result_$index'),
        decoration: BoxDecoration(
          color: _pageSurface(context),
          border: Border.all(color: _pageHairline(context)),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.excerpt,
                style: TextStyle(
                  color: _pageInk(context),
                  fontSize: 15,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${item.memory.kind.name.toUpperCase()} · '
                '${(item.relevanceBasisPoints / 100).round()}% match',
                style: TextStyle(
                  color: _pageInkSoft(context),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ),
      );
}
