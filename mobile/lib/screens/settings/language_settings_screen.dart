import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/app/spoken_language.dart';
import 'settings_components.dart';

/// Settings → Language: the language the user speaks, for the wearable's transcription
/// and the Ask button's dictation.
final class LanguageSettingsScreen extends StatefulWidget {
  const LanguageSettingsScreen({required this.store, super.key});

  final SpokenLanguageStore store;

  @override
  State<LanguageSettingsScreen> createState() => _LanguageSettingsScreenState();
}

final class _LanguageSettingsScreenState extends State<LanguageSettingsScreen> {
  String? _language;
  String? _saving;
  String? _error;

  @override
  void initState() {
    super.initState();
    _language = widget.store.cached;
    unawaited(_load());
  }

  Future<void> _load() async {
    final language = await widget.store.current();
    if (mounted && language != null) setState(() => _language = language);
  }

  Future<void> _choose(String language) async {
    if (language == _language || _saving != null) return;
    setState(() {
      _saving = language;
      _error = null;
    });
    try {
      await widget.store.set(language);
      if (mounted) setState(() => _language = language);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not change the language. Check your connection.');
      }
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Language',
      children: [
        const SettingsMessage(
          'The language you speak. Echo transcribes and takes dictation in it.',
        ),
        const SettingsSection('YOU SPEAK'),
        for (final entry in spokenLanguages.entries)
          SettingsRow(
            key: Key('language-${entry.key}'),
            icon: Icons.translate_rounded,
            title: entry.value,
            onTap: () => unawaited(_choose(entry.key)),
            trailing: _saving == entry.key
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : entry.key == _language
                    ? const Icon(Icons.check_rounded, semanticLabel: 'Selected')
                    : null,
          ),
        if (_error != null) SettingsMessage(_error!, error: true),
      ],
    );
  }
}
