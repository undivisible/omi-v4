import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/overlay_commands.dart';

void main() {
  test('task phrases match the showTasks command', () {
    for (final phrase in [
      'tasks',
      'Tasks',
      'task',
      'my tasks',
      'your tasks',
      'the tasks',
      'show me your tasks',
      'show me my tasks',
      'Show me your tasks!',
      'show tasks',
      'open my tasks',
      'open tasks',
      'view tasks',
      'see my tasks',
      'bring up my tasks',
      'show me the task list',
      'my to-dos',
      'todos',
      'currents',
      'show me my currents',
      'show me your tasks, please',
      'please show me your tasks',
      '  show me your tasks.  ',
    ]) {
      expect(
        matchOverlayCommand(phrase),
        OverlayCommand.showTasks,
        reason: 'expected "$phrase" to match',
      );
    }
  });

  test('sentences that merely mention tasks go to chat', () {
    for (final phrase in [
      '',
      '   ',
      'email my tasks to Sam',
      'what should I do about my tasks today?',
      'add a task to buy milk',
      'summarize my tasks and email them',
      'tasks are boring, write a poem instead',
      'draft a summary of today',
      'show me your calendar',
    ]) {
      expect(
        matchOverlayCommand(phrase),
        isNull,
        reason: 'expected "$phrase" not to match',
      );
    }
  });
}
