import 'dart:async';

import 'package:flutter/material.dart';

import '../currents/currents.dart';
import '../onboarding/hub_checklist.dart';
import '../ui/scroll_edge_fade.dart';

class TasksScreen extends StatefulWidget {
  const TasksScreen({
    required this.controller,
    this.checklistStore,
    this.onAccept,
    super.key,
  });

  final CurrentsController controller;
  final HubChecklistStore? checklistStore;
  final ValueChanged<CurrentCard>? onAccept;

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  bool _setupTaskDone = true;

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.load());
    final store = widget.checklistStore;
    if (store != null) {
      unawaited(
        store
            .isSetupComplete()
            .then((done) {
              if (mounted) setState(() => _setupTaskDone = done);
            })
            .catchError((Object _) {}),
      );
    }
  }

  void _toggleSetupTask() {
    setState(() => _setupTaskDone = !_setupTaskDone);
    final store = widget.checklistStore;
    if (store != null) {
      unawaited(
        store.setSetupComplete(_setupTaskDone).catchError((Object _) {}),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = _TasksColors.of(context);
    return Scaffold(
      backgroundColor: colors.paper,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final controller = widget.controller;
                return ScrollEdgeFade(
                  color: colors.paper,
                  child: ListView(
                    key: const Key('tasks_list'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 28,
                    ),
                    children: [
                      Row(
                        children: [
                          IconButton(
                            key: const Key('tasks_back'),
                            tooltip: 'Back',
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: Icon(
                              Icons.arrow_back_rounded,
                              color: colors.ink,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'ALL TASKS',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.43,
                              color: colors.muted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _SetupRow(
                        done: _setupTaskDone,
                        colors: colors,
                        onToggle: _toggleSetupTask,
                      ),
                      if (controller.loading && controller.items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            'Loading tasks…',
                            key: const Key('tasks_loading'),
                            style: TextStyle(fontSize: 13, color: colors.muted),
                          ),
                        )
                      else if (controller.error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            controller.error!,
                            key: const Key('tasks_error'),
                            style: TextStyle(fontSize: 13, color: colors.muted),
                          ),
                        )
                      else if (controller.items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            'Nothing else needs your attention right now.',
                            key: const Key('tasks_empty'),
                            style: TextStyle(fontSize: 13, color: colors.muted),
                          ),
                        )
                      else
                        for (final task in controller.items)
                          _TaskCardRow(
                            key: ValueKey('tasks_row_${task.item.id}'),
                            task: task,
                            colors: colors,
                            onAccept: widget.onAccept == null
                                ? null
                                : () => widget.onAccept!(task),
                            onComplete: () =>
                                unawaited(controller.dismiss(task.item.id)),
                            onReject: () =>
                                unawaited(controller.dismiss(task.item.id)),
                          ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SetupRow extends StatelessWidget {
  const _SetupRow({
    required this.done,
    required this.colors,
    required this.onToggle,
  });

  final bool done;
  final _TasksColors colors;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: colors.hairline)),
    ),
    child: InkWell(
      key: const Key('tasks_setup_omi'),
      onTap: onToggle,
      child: Opacity(
        opacity: done ? .45 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: [
              _CompleteCircle(
                circleKey: const Key('tasks_complete_setup_omi'),
                done: done,
                colors: colors,
                onTap: onToggle,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  'Set up Omi.',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.ink,
                    decoration: done
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _TaskCardRow extends StatelessWidget {
  const _TaskCardRow({
    required this.task,
    required this.colors,
    required this.onAccept,
    required this.onComplete,
    required this.onReject,
    super.key,
  });

  final CurrentCard task;
  final _TasksColors colors;
  final VoidCallback? onAccept;
  final VoidCallback onComplete;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final id = task.item.id;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.hairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _CompleteCircle(
                  circleKey: ValueKey('tasks_complete_$id'),
                  done: false,
                  colors: colors,
                  onTap: onComplete,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    task.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colors.ink,
                    ),
                  ),
                ),
                _StatusTag(
                  text: task.item.status.name.toUpperCase(),
                  colors: colors,
                ),
                if (task.sourceKind case final tag?) ...[
                  const SizedBox(width: 8),
                  _StatusTag(text: tag.toUpperCase(), colors: colors),
                ],
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 6),
              child: Text(
                task.summary,
                style: TextStyle(
                  fontSize: 12,
                  height: 18 / 12,
                  color: colors.muted,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 8),
              child: Row(
                children: [
                  if (onAccept != null)
                    TextButton(
                      key: ValueKey('tasks_accept_$id'),
                      onPressed: onAccept,
                      style: TextButton.styleFrom(foregroundColor: colors.ink),
                      child: const Text('Accept'),
                    ),
                  TextButton(
                    key: ValueKey('tasks_done_$id'),
                    onPressed: onComplete,
                    style: TextButton.styleFrom(foregroundColor: colors.muted),
                    child: const Text('Complete'),
                  ),
                  TextButton(
                    key: ValueKey('tasks_reject_$id'),
                    onPressed: onReject,
                    style: TextButton.styleFrom(foregroundColor: colors.muted),
                    child: const Text('Reject'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompleteCircle extends StatelessWidget {
  const _CompleteCircle({
    required this.circleKey,
    required this.done,
    required this.colors,
    required this.onTap,
  });

  final Key circleKey;
  final bool done;
  final _TasksColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    key: circleKey,
    onTap: onTap,
    customBorder: const CircleBorder(),
    child: Container(
      width: 16,
      height: 16,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: colors.muted),
      ),
      child: done
          ? Text('✓', style: TextStyle(fontSize: 10, color: colors.ink))
          : null,
    ),
  );
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.text, required this.colors});

  final String text;
  final _TasksColors colors;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: colors.hairline),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.17,
          color: colors.muted,
        ),
      ),
    ),
  );
}

class _TasksColors {
  const _TasksColors._({
    required this.paper,
    required this.ink,
    required this.muted,
    required this.hairline,
  });

  const _TasksColors.light()
    : this._(
        paper: const Color(0xfff7f6f1),
        ink: const Color(0xff171716),
        muted: const Color(0xff8d8980),
        hairline: const Color(0x1a000000),
      );

  const _TasksColors.dark()
    : this._(
        paper: const Color(0xff1c1c1a),
        ink: const Color(0xfff4f2ea),
        muted: const Color(0xffa6a49c),
        hairline: const Color(0x1affffff),
      );

  final Color paper;
  final Color ink;
  final Color muted;
  final Color hairline;

  static _TasksColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const _TasksColors.dark()
      : const _TasksColors.light();
}
