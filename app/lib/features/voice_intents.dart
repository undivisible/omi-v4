final _showHubIntent = RegExp(r'\b(currents?|tasks?)\b', caseSensitive: false);

bool matchesShowHubIntent(String text) => _showHubIntent.hasMatch(text);
