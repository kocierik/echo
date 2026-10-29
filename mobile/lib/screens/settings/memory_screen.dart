import 'package:flutter/material.dart';

import '../../services/api/memory_items_api.dart';
import 'about_you_screen.dart';
import 'documents_screen.dart';
import 'settings_components.dart';

/// Profile → Memory: what Echo knows about you, and your documents.
final class MemoryScreen extends StatelessWidget {
  const MemoryScreen({required this.facts, required this.documents, super.key});

  final AboutYouApi facts;
  final DocumentsApi documents;

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Memory',
      children: [
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
