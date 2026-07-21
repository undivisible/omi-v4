import 'package:flutter/material.dart';

import '../app_services.dart';
import '../memory/memory.dart';
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

  @override
  void initState() {
    super.initState();
    if (!widget.previewMode && widget.services.canUseApi) {
      retrieval = widget.services.memory!.retrieve(query: 'profile');
    }
  }

  @override
  Widget build(BuildContext context) => PageList(
    title: 'Memory',
    subtitle: 'What Omi knows, with sources you can inspect.',
    children: [
      if (retrieval == null)
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
              );
            }
            if (snapshot.hasError) {
              return _StatusTile(
                icon: Icons.error_outline_rounded,
                title: 'Memory could not load',
                detail: '${snapshot.error}',
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

class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => BaseTile(
    icon: icon,
    title: title,
    detail: detail,
    trailing: const SizedBox.shrink(),
  );
}
