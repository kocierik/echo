import 'dart:async';

import 'package:flutter/material.dart';

import '../models/saved.dart';
import '../services/api/api_exception.dart';
import '../services/api/saved_api.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import '../widgets/panel.dart';
import '../widgets/photo_thumbnail.dart';
import '../widgets/sections.dart';
import 'navigation.dart';

/// A saved thing and its moment: the photo, its list, what it is, when, where (if it was
/// asked), who was there and the conversation with the request as said, what Echo read
/// on the photo; then Ask about it, Move to… and Remove from Saved.
final class SavedItemScreen extends StatefulWidget {
  const SavedItemScreen({
    required this.itemId,
    required this.api,
    this.loadPhoto,
    this.onAsk,
    this.openConversation,
    this.openPerson,
    this.clock = DateTime.now,
    super.key,
  });

  final String itemId;
  final SavedApi api;
  final PhotoSourceLoader? loadPhoto;
  final AskCallback? onAsk;
  final ConversationOpener? openConversation;
  final ConversationOpener? openPerson;
  final DateTime Function() clock;

  @override
  State<SavedItemScreen> createState() => _SavedItemScreenState();
}

final class _SavedItemScreenState extends State<SavedItemScreen> {
  SavedItemDetail? _detail;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final detail = await widget.api.getSavedItem(widget.itemId);
      if (mounted) setState(() => _detail = detail);
    } catch (error) {
      if (mounted) setState(() => _error = userMessage(error, 'Could not load this thing.'));
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _move() async {
    List<SavedListChoice> lists;
    try {
      lists = await widget.api.listSavedLists();
    } catch (error) {
      _snack(userMessage(error, 'Could not load the lists.'));
      return;
    }
    if (!mounted) return;
    final current = _detail!.item.listId;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final list in lists.where((l) => l.id != current))
              ListTile(
                key: Key('move-to-${list.id}'),
                title: Text(list.name),
                trailing: Text('${list.count}'),
                onTap: () => Navigator.of(context).pop(list.name),
              ),
            ListTile(
              key: const Key('move-new-list'),
              leading: const Icon(Icons.add_rounded),
              title: const Text('New list…'),
              onTap: () async {
                final name = await _askName(context);
                if (name != null && context.mounted) Navigator.of(context).pop(name);
              },
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.moveSavedItem(widget.itemId, chosen);
      await _load();
      _snack('Moved to $chosen.');
    } catch (error) {
      _snack(userMessage(error, 'Could not move it.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askName(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _NewListDialog(),
    );
    final trimmed = name?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _remove() async {
    final title = _detail!.item.title;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "$title" from Saved?'),
        content: const Text('Its photo and its conversation stay in your memory.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(
            key: const Key('saved-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.deleteSavedItem(widget.itemId);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(userMessage(error, 'Could not remove it.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final detail = _detail;
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: Text(detail?.item.list ?? 'Saved')),
      body: detail == null
          ? (_error == null
              ? const Center(child: CircularProgressIndicator(key: Key('saved-item-loading')))
              : FullScreenMessage(
                  icon: Icons.cloud_off_rounded,
                  title: 'Could not load this thing',
                  message: _error!,
                  actionLabel: 'Retry',
                  onAction: _load,
                ))
          : _content(context, detail),
    );
  }

  Widget _content(BuildContext context, SavedItemDetail detail) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final item = detail.item;
    final ask = widget.onAsk;
    return ListView(
      key: const Key('saved-item'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 48),
      children: [
        if (item.photoId != null && widget.loadPhoto != null)
          PhotoThumbnail(
            photoId: item.photoId!,
            loadSource: widget.loadPhoto!,
            height: 240,
            padding: const EdgeInsets.only(bottom: 16),
            caption: 'Photo from Echo · ${formatTime(item.savedAt)}',
          ),
        Text(
          item.list.toUpperCase(),
          style: textTheme.labelSmall?.copyWith(
            color: palette.accent,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 4),
        Text(item.title, style: textTheme.headlineSmall),
        if (item.details != null) ...[
          const SizedBox(height: 4),
          Text(item.details!, style: textTheme.bodyLarge),
        ],
        if (item.fieldsLine case final fields?) ...[
          const SizedBox(height: 4),
          Text(fields, style: textTheme.bodyMedium?.copyWith(color: palette.text2)),
        ],
        const SizedBox(height: 16),
        _moment(context, detail),
        if (detail.photoText != null) ...[
          const SizedBox(height: 12),
          Panel(
            key: const Key('saved-photo-text'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const PanelHeader(title: 'What Echo read'),
                const SizedBox(height: 6),
                Text(detail.photoText!, style: textTheme.bodyMedium?.copyWith(height: 1.45)),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (ask != null)
          FilledButton.icon(
            key: const Key('saved-ask'),
            onPressed: () => askFromAnywhere(
              context,
              ask,
              'Tell me about "${item.title}" that I saved in ${item.list}: what it is, '
              'and when and with whom I saved it.',
            ),
            icon: const Icon(Icons.auto_awesome_outlined, size: 18),
            label: const Text('Ask about it'),
          ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('saved-move'),
          onPressed: _busy ? null : () => unawaited(_move()),
          child: const Text('Move to…'),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('saved-remove'),
          onPressed: _busy ? null : () => unawaited(_remove()),
          style: TextButton.styleFrom(foregroundColor: palette.red),
          child: const Text('Remove from Saved'),
        ),
      ],
    );
  }

  Widget _moment(BuildContext context, SavedItemDetail detail) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final place = detail.item.place;
    final conversation = detail.conversation;
    final openPerson = widget.openPerson;
    final openConversation = widget.openConversation;
    Widget line(IconData icon, String text, {Key? key}) => Padding(
          key: key,
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: palette.text2),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: textTheme.bodyMedium)),
            ],
          ),
        );
    return Panel(
      key: const Key('saved-moment'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PanelHeader(title: 'The moment'),
          line(Icons.schedule_rounded, longDate(detail.at)),
          if (place != null)
            line(Icons.place_outlined, place.address ?? 'A place without an address',
                key: const Key('saved-moment-place')),
          if (detail.people.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final person in detail.people)
                    ActionChip(
                      key: Key('saved-person-${person.name}'),
                      label: Text(person.name),
                      onPressed: person.id == null || openPerson == null
                          ? null
                          : () => unawaited(openPerson(context, person.id!)),
                    ),
                ],
              ),
            ),
          if (conversation != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Material(
                color: palette.surface2,
                borderRadius: BorderRadius.circular(AppTheme.tileRadius),
                child: InkWell(
                  key: const Key('saved-moment-conversation'),
                  borderRadius: BorderRadius.circular(AppTheme.tileRadius),
                  onTap: openConversation == null
                      ? null
                      : () => unawaited(openConversation(context, conversation.id)),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(conversation.title ?? 'Conversation', style: textTheme.titleSmall),
                        if (conversation.duration > Duration.zero)
                          Text(formatDuration(conversation.duration), style: textTheme.bodySmall),
                        if (detail.request != null) ...[
                          const SizedBox(height: 6),
                          Text('"${detail.request}"', style: textTheme.bodyMedium),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            )
          else if (detail.request != null)
            line(Icons.format_quote_rounded, '"${detail.request}"'),
        ],
      ),
    );
  }
}

/// The name of a new list, for "Move to…".
final class _NewListDialog extends StatefulWidget {
  const _NewListDialog();

  @override
  State<_NewListDialog> createState() => _NewListDialogState();
}

final class _NewListDialogState extends State<_NewListDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New list'),
      content: TextField(
        key: const Key('new-list-name'),
        controller: _name,
        autofocus: true,
        maxLength: 80,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(
          key: const Key('new-list-create'),
          onPressed: () => Navigator.of(context).pop(_name.text),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

const _weekdays = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
];

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// "Saturday 18 October, 21:40".
String longDate(DateTime at) {
  final local = at.toLocal();
  return '${_weekdays[local.weekday - 1]} ${local.day} ${_months[local.month - 1]}, '
      '${formatTime(local)}';
}
