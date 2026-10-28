import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/app/spoken_language.dart';
import '../../theme/app_theme.dart';
import 'settings_components.dart';

/// Settings → Language: the language the user speaks, for the wearable's transcription
/// and the Ask button's dictation, and the other languages spoken around them (Echo
/// recognises which one each segment is in; the app translates them).
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

  /// Null until the account says (offline: the section is not shown).
  List<String>? _others;
  bool _savingOthers = false;

  @override
  void initState() {
    super.initState();
    _language = widget.store.cached;
    unawaited(_load());
  }

  Future<void> _load() async {
    final language = await widget.store.current();
    if (mounted && language != null) setState(() => _language = language);
    final others = await widget.store.otherLanguages();
    if (mounted && others != null) setState(() => _others = others);
  }

  Future<void> _toggleOther(String code) async {
    final before = _others;
    if (before == null || _savingOthers) return;
    final next = before.contains(code) ? [...before.where((c) => c != code)] : [...before, code];
    setState(() {
      _others = next;
      _savingOthers = true;
      _error = null;
    });
    try {
      final kept = await widget.store.setOtherLanguages(next);
      if (mounted) setState(() => _others = kept);
    } catch (_) {
      if (mounted) {
        setState(() {
          _others = before;
          _error = 'Could not change the other languages. Check your connection.';
        });
      }
    } finally {
      if (mounted) setState(() => _savingOthers = false);
    }
  }

  Future<void> _choose(String language) async {
    if (language == _language || _saving != null) return;
    setState(() {
      _saving = language;
      _error = null;
    });
    try {
      await widget.store.set(language);
      // The server drops the new main language from the other ones
      if (mounted) {
        setState(() {
          _language = language;
          _others = _others?.where((code) => code != language).toList();
        });
      }
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
    final palette = EchoPalette.of(context);
    final others = _others;
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
        if (others != null) ...[
          const SettingsSection('YOU ALSO HEAR'),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Other languages spoken around you. Echo recognises which one each '
              'conversation is in, and offers to translate it into yours.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final MapEntry(key: code, value: name) in heardLanguages.entries)
                  if (code != _language)
                    FilterChip(
                      key: Key('other-language-$code'),
                      label: Text(name),
                      selected: others.contains(code),
                      onSelected: others.contains(code) || others.length < maxOtherLanguages
                          ? (_) => unawaited(_toggleOther(code))
                          : null,
                    ),
              ],
            ),
          ),
        ],
        if (_error != null) SettingsMessage(_error!, error: true),
      ],
    );
  }
}
