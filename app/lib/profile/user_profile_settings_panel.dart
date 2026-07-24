import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../profile/user_profile.dart';

class UserProfileSettingsPanel extends StatefulWidget {
  const UserProfileSettingsPanel({
    required this.services,
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final bool previewMode;

  @override
  State<UserProfileSettingsPanel> createState() =>
      _UserProfileSettingsPanelState();
}

class _UserProfileSettingsPanelState extends State<UserProfileSettingsPanel> {
  final _store = PreferencesUserProfileStore();
  final _customPrompt = TextEditingController();
  final _sectionControllers = <String, TextEditingController>{};
  final _name = TextEditingController();
  final _languages = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _saved;

  @override
  void initState() {
    super.initState();
    for (final section in userProfileSoulSections) {
      _sectionControllers[section] = TextEditingController();
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    _customPrompt.dispose();
    _name.dispose();
    _languages.dispose();
    for (final controller in _sectionControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String? get _uid => widget.services.auth.snapshot.session?.uid;

  Future<void> _load() async {
    final uid = _uid;
    if (uid == null) {
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }
    final document = await _store.load(uid);
    final name = document.name ??
        widget.services.auth.snapshot.session?.displayName ??
        await widget.services.localProfileName();
    if (!mounted) return;
    _name.text = name ?? '';
    _languages.text = document.languages.join(', ');
    _customPrompt.text = document.customPrompt;
    for (final section in userProfileSoulSections) {
      _sectionControllers[section]?.text = document.soul[section] ?? '';
    }
    setState(() {
      _loading = false;
      _error = null;
    });
  }

  Future<void> _save() async {
    final uid = _uid;
    if (uid == null || _saving || widget.previewMode) return;
    setState(() {
      _saving = true;
      _error = null;
      _saved = null;
    });
    final languages = _languages.text
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    final soul = <String, String>{};
    for (final section in userProfileSoulSections) {
      final text = _sectionControllers[section]?.text.trim() ?? '';
      if (text.isNotEmpty) soul[section] = text;
    }
    final trimmedName = _name.text.trim();
    final document = UserProfileDocument(
      name: trimmedName.isEmpty ? null : trimmedName,
      languages: languages,
      soul: soul,
      customPrompt: _customPrompt.text,
    );
    try {
      await _store.save(uid, document);
      final databasePath = await widget.services.memoryDatabasePath(uid);
      await _store.writeSidecar(databasePath, document);
      final memory = widget.services.memory;
      if (memory != null) {
        unawaited(
          syncUserProfileToMemory(memory: memory, document: document).catchError(
            (_) {},
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved = 'Saved. Omi will use this in assistant prompts.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save your profile. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.previewMode) {
      return const ListTile(
        title: Text('Personal context'),
        subtitle: Text('Sign in to edit the profile Omi uses in prompts.'),
      );
    }
    if (_uid == null) {
      return const ListTile(
        title: Text('Personal context'),
        subtitle: Text('Sign in to edit beliefs, goals, and other profile notes.'),
      );
    }
    if (_loading) {
      return const ListTile(
        title: Text('Personal context'),
        trailing: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: Text(
            'Personal context',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Text(
            'These notes are injected into assistant prompts — beliefs, goals, '
            'preferences, and the rest. They complement memory Omi learns over time.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        _field(label: 'Name', controller: _name),
        _field(
          label: 'Languages',
          controller: _languages,
          hint: 'English, Spanish',
        ),
        for (final section in userProfileSoulSections)
          _field(
            label: section,
            controller: _sectionControllers[section]!,
            minLines: 2,
          ),
        _field(
          label: 'Custom instructions',
          controller: _customPrompt,
          minLines: 3,
          hint: 'Anything else Omi should always know…',
        ),
        if (_error case final message?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Text(message, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (_saved case final message?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const Key('save_user_profile'),
              onPressed: _saving ? null : () => unawaited(_save()),
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save profile'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    String? hint,
    int minLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            minLines: minLines,
            maxLines: minLines + 4,
            decoration: InputDecoration(
              hintText: hint ?? '$label…',
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}
