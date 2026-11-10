import 'dart:async';

import 'package:flutter/material.dart';

import '../services/memory/memories_controller.dart';
import '../theme/app_theme.dart';
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

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final state = widget.controller.state;
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        title: const Text('People'),
        actions: [
          TextButton.icon(
            key: const Key('people-map'),
            onPressed: () => unawaited(widget.onOpenMap()),
            icon: const Icon(Icons.hub_outlined),
            label: const Text('Map'),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                key: const Key('people-filter'),
                controller: _filter,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Search people',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
            ),
            Expanded(child: _list(state)),
          ],
        ),
      ),
    );
  }

  Widget _list(MemoriesState state) {
    final controller = widget.controller;
    if (state.peopleLoading || !state.peopleLoaded) {
      return const Center(child: CircularProgressIndicator(key: Key('people-loading')));
    }
    if (state.people.isEmpty) {
      if (state.peopleError != null) {
        return FullScreenMessage(
          icon: Icons.cloud_off_rounded,
          title: 'Could not load people',
          message: state.peopleError!,
          actionKey: const Key('people-retry'),
          actionLabel: 'Retry',
          onAction: controller.loadPeople,
          onRefresh: controller.loadPeople,
        );
      }
      return FullScreenMessage(
        icon: Icons.people_outline_rounded,
        title: 'No people yet',
        message: 'People you talk with or about show up here.',
        onRefresh: controller.loadPeople,
      );
    }
    final query = _filter.text.trim().toLowerCase();
    final people = query.isEmpty
        ? state.people
        : state.people.where((p) => p.name.toLowerCase().contains(query)).toList();
    if (people.isEmpty) {
      return FullScreenMessage(
        icon: Icons.search_off_rounded,
        title: 'No one matches',
        message: 'Nobody named "${_filter.text.trim()}" yet.',
      );
    }
    return RefreshIndicator(
      onRefresh: controller.loadPeople,
      child: ListView.builder(
        key: const Key('people-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        itemCount: people.length,
        itemBuilder: (context, index) => PersonTile(
          person: people[index],
          now: widget.now,
          onTap: () => unawaited(widget.onOpenPerson(people[index].id)),
        ),
      ),
    );
  }
}
