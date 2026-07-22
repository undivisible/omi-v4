import 'package:flutter/material.dart';

import '../currents/currents.dart';
import '../ui/omi_ui.dart';

class CurrentsScreen extends StatefulWidget {
  const CurrentsScreen({super.key, this.controller, this.onActionHandoff});

  final CurrentsController? controller;
  final Future<void> Function(CurrentActionHandoff handoff)? onActionHandoff;

  @override
  State<CurrentsScreen> createState() => _CurrentsScreenState();
}

class _CurrentsScreenState extends State<CurrentsScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_changed);
    widget.controller?.load();
  }

  @override
  void didUpdateWidget(CurrentsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller?.removeListener(_changed);
    widget.controller?.addListener(_changed);
    widget.controller?.load();
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final children = <Widget>[];
    if (controller?.loading ?? false) {
      children.add(const LinearProgressIndicator());
    } else if (controller?.error case final error?) {
      children.add(
        BaseTile(
          icon: Icons.error_outline_rounded,
          title: 'Currents unavailable',
          detail: error,
          trailing: IconButton(
            tooltip: 'Retry',
            onPressed: controller!.load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
      );
    } else if (controller == null || controller.items.isEmpty) {
      children.add(
        const BaseTile(
          icon: Icons.waves_rounded,
          title: 'No Currents yet',
          detail: 'Omi will surface cited opportunities here.',
          trailing: Icon(Icons.hourglass_empty_rounded),
        ),
      );
    } else {
      children.addAll(
        controller.items.map(
          (card) => _CurrentTile(
            card: card,
            onDismiss: () => controller.dismiss(card.item.id),
            onSnooze: () => controller.snooze(
              card.item.id,
              DateTime.now().add(const Duration(days: 1)),
            ),
            onAccept: widget.onActionHandoff == null
                ? null
                : () async {
                    final handoff = await controller.accept(card.item.id);
                    await widget.onActionHandoff!(handoff);
                  },
          ),
        ),
      );
    }
    return PageList(
      title: 'Currents',
      subtitle: 'Patterns and opportunities moving through your life.',
      children: children,
    );
  }
}

class _CurrentTile extends StatelessWidget {
  const _CurrentTile({
    required this.card,
    required this.onDismiss,
    required this.onSnooze,
    required this.onAccept,
  });

  final CurrentCard card;
  final VoidCallback onDismiss;
  final VoidCallback onSnooze;
  final VoidCallback? onAccept;

  @override
  Widget build(BuildContext context) => BaseTile(
    icon: Icons.waves_rounded,
    title: card.title,
    detail:
        '${card.summary}\n${card.item.reason} · Source: ${card.item.evidence.firstOrNull?.sourceId ?? '—'}',
    trailing: Wrap(
      children: [
        IconButton(
          tooltip: 'Dismiss',
          onPressed: onDismiss,
          icon: const Icon(Icons.close_rounded),
        ),
        IconButton(
          tooltip: 'Snooze for one day',
          onPressed: onSnooze,
          icon: const Icon(Icons.snooze_rounded),
        ),
        if (onAccept != null)
          IconButton(
            tooltip: card.item.proposedNextStep,
            onPressed: onAccept,
            icon: const Icon(Icons.arrow_forward_rounded),
          ),
      ],
    ),
  );
}
