import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/api/memory_items_api.dart';
import '../../services/app/spoken_language.dart';
import 'about_you_screen.dart';
import 'documents_screen.dart';
import 'instructions_screen.dart';
import 'settings_components.dart';

/// Account sheet → About you: how Echo talks to you, what it knows about you, your documents.
final class MemoryScreen extends StatefulWidget {
  const MemoryScreen({
    required this.facts,
    required this.documents,
    required this.instructions,
    required this.account,
    this.knownAccount,
    super.key,
  });

  final AboutYouApi facts;
  final DocumentsApi documents;
  final InstructionsApi instructions;
  final AccountApi account;

  /// The account the caller already has; fetched here when null.
  final AccountInfo? knownAccount;

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

final class _MemoryScreenState extends State<MemoryScreen> {
  AccountInfo? _info;

  @override
  void initState() {
    super.initState();
    _info = widget.knownAccount;
    if (_info == null) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final info = await widget.account.me();
      if (mounted) setState(() => _info = info);
    } catch (_) {}
  }

  Future<void> _editInstructions() async {
    final saved = await Navigator.push<AccountInfo>(
      context,
      MaterialPageRoute(
        builder: (_) => InstructionsScreen(
            api: widget.instructions, initial: _info?.instructions),
      ),
    );
    if (saved != null && mounted) setState(() => _info = saved);
  }

  @override
  Widget build(BuildContext context) {
    final facts = widget.facts;
    final documents = widget.documents;
    return SettingsPageScaffold(
      title: 'About you',
      children: [
        SettingsRow(
          key: const Key('memory-instructions'),
          icon: Icons.tune_rounded,
          title: 'Instructions',
          // Not editable until the account is known: an empty editor would save over them
          subtitle: _info == null
              ? 'Loading…'
              : _info!.instructions?.split('\n').first ??
                  'How Echo talks to you.',
          onTap: _info == null ? null : _editInstructions,
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
            MaterialPageRoute<void>(
                builder: (_) => DocumentsScreen(api: documents)),
          ),
        ),
      ],
    );
  }
}
