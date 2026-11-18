import 'package:flutter/material.dart';

import '../../services/api/memory_items_api.dart';
import '../../services/app/spoken_language.dart';
import 'about_you_screen.dart';
import 'documents_screen.dart';
import 'instructions_screen.dart';
import 'settings_components.dart';

/// Account sheet → About you: how Echo talks to you, what it knows about you, your documents.
final class MemoryScreen extends StatelessWidget {
  const MemoryScreen({
    required this.facts,
    required this.documents,
    required this.instructions,
    this.instructionsText,
    super.key,
  });

  final AboutYouApi facts;
  final DocumentsApi documents;
  final InstructionsApi instructions;

  /// What the editor starts with.
  final String? instructionsText;

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'About you',
      children: [
        SettingsRow(
          key: const Key('memory-instructions'),
          icon: Icons.tune_rounded,
          title: 'Instructions',
          subtitle: instructionsText?.split('\n').first ?? 'How Echo talks to you.',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => InstructionsScreen(api: instructions, initial: instructionsText),
            ),
          ),
        ),
        SettingsRow(
          key: const Key('memory-about-you'),
          icon: Icons.person_outline_rounded,
          title: 'About you',
          subtitle: 'What Echo knows about you, in every answer.',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => AboutYouScreen(api: facts)),
          ),
        ),
        SettingsRow(
          key: const Key('memory-documents'),
          icon: Icons.description_outlined,
          title: 'Documents',
          subtitle: 'Files Echo searches when it answers you.',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => DocumentsScreen(api: documents)),
          ),
        ),
      ],
    );
  }
}
