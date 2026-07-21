import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../memory/memory.dart';
import '../native/generated/signals/signals.dart';
import '../ui/omi_ui.dart';

class MemoryScreen extends StatefulWidget {
  const MemoryScreen({
    required this.services,
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final bool previewMode;

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  Future<RetrievalPack>? retrieval;
  NativeMemoryController? nativeMemory;
  final searchController = TextEditingController(text: 'profile');

  @override
  void initState() {
    super.initState();
    if (!widget.previewMode && !kIsWeb) {
      nativeMemory = NativeMemoryController(
        hub: widget.services.nativeHub,
        events: widget.services.nativeEvents,
      )..start();
      widget.services.auth.addListener(_authChanged);
      _searchNativeIfReady();
    } else if (!widget.previewMode && widget.services.canUseApi) {
      retrieval = widget.services.memory!.retrieve(query: 'profile');
    }
  }

  @override
  void dispose() {
    widget.services.auth.removeListener(_authChanged);
    nativeMemory?.dispose();
    searchController.dispose();
    super.dispose();
  }

  void _authChanged() {
    if (!mounted) return;
    setState(_searchNativeIfReady);
  }

  void _searchNativeIfReady() {
    if (_canUseNative &&
        nativeMemory!.items.isEmpty &&
        !nativeMemory!.loading) {
      nativeMemory!.search(searchController.text);
    }
  }

  bool get _canUseNative =>
      !widget.previewMode &&
      !kIsWeb &&
      widget.services.nativeHub.available &&
      widget.services.productionReady;

  @override
  Widget build(BuildContext context) => PageList(
    title: 'Memory',
    subtitle: 'What Omi knows, with sources you can inspect.',
    children: [
      if (nativeMemory != null && _canUseNative)
        _NativeMemoryView(
          controller: nativeMemory!,
          searchController: searchController,
        )
      else if (retrieval == null)
        _StatusTile(
          icon: Icons.cloud_off_outlined,
          title: 'Memory is not connected',
          detail: widget.previewMode
              ? 'Memory access is disabled in the interface preview.'
              : widget.services.configurationMessage,
        )
      else
        FutureBuilder<RetrievalPack>(
          future: retrieval,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _StatusTile(
                icon: Icons.sync_rounded,
                title: 'Loading memory',
                detail: 'Retrieving your latest memories…',
                liveRegion: true,
              );
            }
            if (snapshot.hasError) {
              return _StatusTile(
                icon: Icons.error_outline_rounded,
                title: 'Memory could not load',
                detail: '${snapshot.error}',
                liveRegion: true,
              );
            }
            final items = snapshot.data!.items;
            if (items.isEmpty) {
              return const _StatusTile(
                icon: Icons.auto_stories_outlined,
                title: 'No memories yet',
                detail: 'Captured memories will appear here with sources.',
              );
            }
            return Column(
              children: [
                for (final item in items)
                  _StatusTile(
                    icon: Icons.auto_stories_outlined,
                    title: item.excerpt,
                    detail:
                        '${item.memory.kind.name} · ${item.evidenceIds.length} sources',
                  ),
              ],
            );
          },
        ),
    ],
  );
}

class _NativeMemoryView extends StatelessWidget {
  const _NativeMemoryView({
    required this.controller,
    required this.searchController,
  });

  final NativeMemoryController controller;
  final TextEditingController searchController;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Column(
      children: [
        TextField(
          controller: searchController,
          textInputAction: TextInputAction.search,
          onSubmitted: controller.search,
          decoration: InputDecoration(
            hintText: 'Search your memory',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: IconButton(
              tooltip: 'Search memory',
              onPressed: controller.loading
                  ? null
                  : () => controller.search(searchController.text),
              icon: const Icon(Icons.arrow_forward_rounded),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (controller.loading)
          const _StatusTile(
            icon: Icons.sync_rounded,
            title: 'Loading memory',
            detail: 'Searching your local memory…',
            liveRegion: true,
          )
        else if (controller.error case final error?)
          _StatusTile(
            icon: Icons.error_outline_rounded,
            title: 'Memory could not load',
            detail: error,
            liveRegion: true,
          )
        else if (controller.items.isEmpty)
          _StatusTile(
            icon: Icons.auto_stories_outlined,
            title: 'No memories found',
            detail: controller.gaps.isEmpty
                ? 'Try a different search.'
                : controller.gaps.join(' '),
          )
        else
          for (final item in controller.items)
            _NativeMemoryTile(item: item, controller: controller),
      ],
    ),
  );
}

class _NativeMemoryTile extends StatelessWidget {
  const _NativeMemoryTile({required this.item, required this.controller});

  final MemorySearchItem item;
  final NativeMemoryController controller;

  @override
  Widget build(BuildContext context) => BaseTile(
    icon: Icons.auto_stories_outlined,
    title: item.excerpt,
    detail: '${item.kind} · ${item.evidenceIds.length} sources',
    trailing: item.kind == 'claim' || item.kind == 'source'
        ? MenuAnchor(
            builder: (context, menu, _) => IconButton(
              tooltip: 'Memory actions',
              onPressed: menu.isOpen ? menu.close : menu.open,
              icon: const Icon(Icons.more_horiz_rounded),
            ),
            menuChildren: [
              if (item.kind == 'claim')
                MenuItemButton(
                  onPressed: () => _correct(context),
                  child: const Text('Correct'),
                ),
              if (item.kind == 'source')
                MenuItemButton(
                  onPressed: () => _delete(context),
                  child: const Text('Delete source'),
                ),
            ],
          )
        : const SizedBox.shrink(),
  );

  Future<void> _correct(BuildContext context) async {
    final text = TextEditingController(text: item.excerpt);
    final value = TextEditingController(text: item.excerpt);
    final result = await showDialog<({String text, String value})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Correct memory'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: text,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Correction'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: value,
              decoration: const InputDecoration(labelText: 'Correct value'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, (text: text.text, value: value.text)),
            child: const Text('Save correction'),
          ),
        ],
      ),
    );
    text.dispose();
    value.dispose();
    if (result == null) return;
    controller.correct(
      claimId: item.id,
      text: result.text,
      value: result.value,
    );
  }

  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this source?'),
        content: const Text(
          'Its evidence will no longer be used by your memory.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) controller.deleteSource(item.id);
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.icon,
    required this.title,
    required this.detail,
    this.liveRegion = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: liveRegion,
    child: BaseTile(
      icon: icon,
      title: title,
      detail: detail,
      trailing: const SizedBox.shrink(),
    ),
  );
}
