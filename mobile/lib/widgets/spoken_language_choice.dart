import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app/spoken_language.dart';
import '../theme/app_theme.dart';

/// The languages Echo transcribes the user in (the server's SUPPORTED_LANGUAGES).
const spokenLanguageNames = {'it': 'Italiano', 'en': 'English'};

/// "You speak to Echo in": Italian or English, saved on the account at once.
///
/// A new account takes the phone's language: a phone in English made Echo transcribe
/// Italian speech as English. Asked before Echo listens (setup, recording the voice).
final class SpokenLanguageChoice extends StatefulWidget {
  const SpokenLanguageChoice({required this.store, this.onChanged, this.enabled = true, super.key});

  final SpokenLanguageStore store;

  /// The language chosen, once the account has it.
  final ValueChanged<String>? onChanged;
  final bool enabled;

  @override
  State<SpokenLanguageChoice> createState() => _SpokenLanguageChoiceState();
}

final class _SpokenLanguageChoiceState extends State<SpokenLanguageChoice> {
  String? _language;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _language = widget.store.cached;
    unawaited(_load());
  }

  Future<void> _load() async {
    final language = await widget.store.current();
    if (!mounted || language == null) return;
    setState(() => _language = language);
    widget.onChanged?.call(language);
  }

  Future<void> _choose(String language) async {
    final previous = _language;
    setState(() {
      _language = language;
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.set(language);
      widget.onChanged?.call(language);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _language = previous;
        _error = 'Could not change the language. Check your connection.';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final language = _language;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('You speak to Echo in', style: textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          key: const Key('spoken-language'),
          showSelectedIcon: false,
          emptySelectionAllowed: true,
          segments: [
            for (final entry in spokenLanguageNames.entries)
              ButtonSegment(value: entry.key, label: Text(entry.value)),
          ],
          selected: {if (language != null) language},
          onSelectionChanged: widget.enabled && !_saving
              ? (selected) {
                  if (selected.isNotEmpty) unawaited(_choose(selected.first));
                }
              : null,
        ),
        const SizedBox(height: 6),
        Text(
          _error ?? 'What Echo hears is transcribed in it, whatever language your phone is in.',
          style: textTheme.bodySmall?.copyWith(color: _error == null ? palette.text2 : palette.red),
        ),
      ],
    );
  }
}
