/// Commands the centered input overlay understands directly. Typed text that
/// matches one of these executes the command on Enter instead of being sent
/// to chat; everything else routes to chat unchanged.
enum OverlayCommand { showTasks }

final _tasksCommandPattern = RegExp(
  r'^(?:please\s+)?'
  r'(?:(?:show|open|view|see|bring\s+up)\s+)?'
  r'(?:me\s+)?'
  r'(?:your|my|the)?\s*'
  r'(?:tasks?|currents?|to-?dos?)'
  r'(?:\s+(?:view|list|page))?'
  r'(?:\s+please)?$',
);

/// Matches the trimmed, lowercased input against the known overlay commands.
/// Deliberately anchored: "show me your tasks", "my tasks", or "tasks" match;
/// a sentence that merely mentions tasks ("email my tasks to Sam") does not.
OverlayCommand? matchOverlayCommand(String input) {
  final normalized = input
      .toLowerCase()
      .replaceAll(RegExp(r'[.!?,]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) return null;
  if (_tasksCommandPattern.hasMatch(normalized)) {
    return OverlayCommand.showTasks;
  }
  return null;
}
