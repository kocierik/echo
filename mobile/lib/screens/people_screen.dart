import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoButton, CupertinoIcons, CupertinoSearchTextField;
import 'package:flutter/material.dart';

import '../services/api/api_exception.dart';
import '../services/memory/memories_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/echo_grouped.dart';
import '../widgets/echo_large_title.dart';
import '../widgets/sections.dart';
import 'person_screen.dart';

/// Everyone Echo heard about, from Memories' "All": a name filter and the list.
final class PeopleScreen extends StatefulWidget {
  const PeopleScreen({
    required this.controller,
    required this.onOpenPerson,
    required this.onOpenMap,
    required this.now,
    super.key,
  });

  /// Memories' controller: the same people, loaded once.
  final MemoriesController controller;
  final Future<void> Function(String id) onOpenPerson;
  final Future<void> Function() onOpenMap;
  final DateTime now;

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

final class _PeopleScreenState extends State<PeopleScreen> {
  final _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    if (!widget.controller.state.peopleLoaded) unawaited(widget.controller.loadPeople());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _filter.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Only people added here are kept from what Echo hears.
  Future<void> _addPerson() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        final field = TextEditingController();
        return AlertDialog(
          title: const Text('Add person'),
          content: TextField(
            key: const Key('people-add-name'),
            controller: field,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('people-add-confirm'),
              onPressed: () => Navigator.of(context).pop(field.text),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.controller.addPerson(trimmed);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(userMessage(error, 'Could not add this person.'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return EchoLargeTitlePage(
      title: 'People',
      onRefresh: widget.controller.loadPeople,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoButton(
            key: const Key('people-add'),
            minimumSize: const Size(44, 44),
            padding: EdgeInsets.zero,
            onPressed: () => unawaited(_addPerson()),
            child: Icon(CupertinoIcons.person_add, color: palette.accent, semanticLabel: 'Add person'),
          ),
          CupertinoButton(
            key: const Key('people-map'),
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onPressed: () => unawaited(widget.onOpenMap()),
            child: Text('Map', style: TextStyle(color: palette.accent)),
          ),
        ],
      ),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: CupertinoSearchTextField(
              key: const Key('people-filter'),
              controller: _filter,
              placeholder: 'Search people',
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
        ..._list(widget.controller.state),
      ],
    );
  }

  List<Widget> _list(MemoriesState state) {
    final controller = widget.controller;
    if (state.peopleLoading || !state.peopleLoaded) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator(key: Key('people-loading'))),
        ),
      ];
    }
    if (state.people.isEmpty) {
      if (state.peopleError != null) {
        return [
          FullScreenMessage(
            sliver: true,
            icon: CupertinoIcons.cloud_bolt,
            title: 'Could not load people',
            message: state.peopleError!,
            actionKey: const Key('people-retry'),
            actionLabel: 'Retry',
            onAction: controller.loadPeople,
          ),
        ];
      }
      return [
        FullScreenMessage(
          sliver: true,
          icon: CupertinoIcons.person_2,
          title: 'No people yet',
          message: 'Add the people you want Echo to remember: what is said with or about '
              'them is kept from then on.',
          actionKey: const Key('people-add-first'),
          actionLabel: 'Add person',
          onAction: _addPerson,
        ),
      ];
    }
    final query = _filter.text.trim().toLowerCase();
    final people = query.isEmpty
        ? state.people
        : state.people.where((p) => p.name.toLowerCase().contains(query)).toList();
    if (people.isEmpty) {
      return [
        FullScreenMessage(
          sliver: true,
          icon: CupertinoIcons.search,
          title: 'No one matches',
          message: 'Nobody named "${_filter.text.trim()}" yet.',
        ),
      ];
    }
    // shortcut: one non-lazy group, fine for the people one person knows; page it if lists grow large.
    return [
      SliverToBoxAdapter(
        child: EchoGroup(
          key: const Key('people-list'),
          children: [
            for (final person in people)
              PersonTile(
                person: person,
                now: widget.now,
                onTap: () => unawaited(widget.onOpenPerson(person.id)),
              ),
          ],
        ),
      ),
    ];
  }
}
