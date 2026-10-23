import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/api/api_exception.dart';
import '../../services/app/spoken_language.dart';
import '../../theme/app_theme.dart';

/// Profile → Instructions: how Echo should talk to the user and what it should know,
/// used in every answer (chat, voice, routines, photos). Goes back with the saved account.
class InstructionsScreen extends StatefulWidget {
  const InstructionsScreen({required this.api, this.initial, super.key});

  final InstructionsApi api;
  final String? initial;

  /// The server keeps at most this much (services/personal.py).
  static const maxLength = 1000;

  static const examples = [
    'Keep answers short',
    'Use an informal tone',
    'My work chats are on Slack',
    'Give amounts in euros',
  ];

  @override
  State<InstructionsScreen> createState() => _InstructionsScreenState();
}

class _InstructionsScreenState extends State<InstructionsScreen> {
  late final TextEditingController _text = TextEditingController(text: widget.initial ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _add(String example) {
    final current = _text.text.trimRight();
    final line = '$example.';
    final next = current.isEmpty ? line : '$current\n$line';
    if (next.length > InstructionsScreen.maxLength) return;
    _text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final text = _text.text.trim();
      final account = await widget.api.setInstructions(text.isEmpty ? null : text);
      if (mounted) Navigator.pop(context, account);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(
            error is ApiException ? error.message : 'Could not save your instructions.',
          ),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        title: const Text('Instructions'),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => unawaited(_save()),
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'How Echo should talk to you, and what it should keep in mind. It follows '
            'them in every answer, by chat and by voice. Actions for other people still '
            'wait for your Confirm.',
            style: textTheme.bodyMedium?.copyWith(color: palette.text2),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('instructions-field'),
            controller: _text,
            maxLines: 8,
            minLines: 5,
            maxLength: InstructionsScreen.maxLength,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'Keep answers short. My work chats are on Slack.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text('EXAMPLES', style: textTheme.labelMedium?.copyWith(color: palette.text2)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final example in InstructionsScreen.examples)
                ActionChip(label: Text(example), onPressed: () => _add(example)),
            ],
          ),
        ],
      ),
    );
  }
}
