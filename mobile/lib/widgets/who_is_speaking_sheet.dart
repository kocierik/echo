import 'package:flutter/material.dart';

import '../models/person.dart';
import '../theme/app_theme.dart';

/// What the user answered to "Who is speaking?".
@immutable
final class VoiceChoice {
  const VoiceChoice.me()
      : isSelf = true,
        personId = null,
        name = null;
  const VoiceChoice.person(String this.personId)
      : isSelf = false,
        name = null;
  const VoiceChoice.named(String this.name)
      : isSelf = false,
        personId = null;

  final bool isSelf;
  final String? personId;
  final String? name;
}

/// Me, one of the user's people, or a new name.
Future<VoiceChoice?> showWhoIsSpeaking(
  BuildContext context, {
  required List<PersonSummary> people,
}) {
  return showModalBottomSheet<VoiceChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => WhoIsSpeakingSheet(people: people),
  );
}

final class WhoIsSpeakingSheet extends StatefulWidget {
  const WhoIsSpeakingSheet({required this.people, super.key});

  final List<PersonSummary> people;

  @override
  State<WhoIsSpeakingSheet> createState() => _WhoIsSpeakingSheetState();
}

final class _WhoIsSpeakingSheetState extends State<WhoIsSpeakingSheet> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _saveName() {
    final name = _name.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, VoiceChoice.named(name));
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text('Who is speaking?', style: textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Echo learns this voice and labels it in the rest of the conversation.',
                style: textTheme.bodySmall,
              ),
            ),
            ListTile(
              key: const Key('voice-me'),
              leading: Icon(Icons.person_rounded, color: palette.blue),
              title: const Text('Me'),
              onTap: () => Navigator.pop(context, const VoiceChoice.me()),
            ),
            for (final person in widget.people.take(20))
              ListTile(
                key: Key('voice-person-${person.id}'),
                leading: const Icon(Icons.person_outline_rounded),
                title: Text(person.name),
                subtitle: person.role == null ? null : Text(person.role!),
                onTap: () => Navigator.pop(context, VoiceChoice.person(person.id)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 12, 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('voice-new-name'),
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(hintText: 'Someone else: their name'),
                      onSubmitted: (_) => _saveName(),
                    ),
                  ),
                  TextButton(
                    key: const Key('voice-save-name'),
                    onPressed: _saveName,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
