import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/api/demo_api.dart';
import 'settings_components.dart';

/// Profile → Example data: a few days of example conversations (with people, tasks and
/// events), things about you, saved things and places, to see Echo filled in. Off deletes
/// them, and only them: what Echo heard and what you added stay.
final class ExampleDataScreen extends StatefulWidget {
  const ExampleDataScreen({required this.api, super.key});

  final ExampleDataApi api;

  @override
  State<ExampleDataScreen> createState() => _ExampleDataScreenState();
}

final class _ExampleDataScreenState extends State<ExampleDataScreen> {
  bool? _on;
  bool _busy = false;

  /// Turned on here: the conversations are still being read.
  bool _justOn = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final on = await widget.api.exampleDataOn();
      if (mounted) setState(() => _on = on);
    } catch (_) {
      if (mounted) setState(() => _error = 'Echo could not check it. Try again later.');
    }
  }

  Future<void> _set(bool on) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final now = await widget.api.setExampleData(on);
      if (mounted) {
        setState(() {
          _on = now;
          _justOn = now;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = on
            ? 'Echo could not add the examples. Try again.'
            : 'Echo could not remove the examples. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = _on;
    return SettingsPageScaffold(
      title: 'Example data',
      children: [
        const SettingsMessage(
          'A few days of example conversations, with the people, tasks and plans in them, '
          'some things about you, saved things and places: to see Echo filled in before '
          'it has heard anything. Turn it off and they are deleted, only them.',
        ),
        const SizedBox(height: 12),
        SettingsRow(
          icon: Icons.auto_awesome_motion_outlined,
          title: 'Example data',
          subtitle: switch (on) {
            null => null,
            true => 'On',
            false => 'Off',
          },
          trailing: on == null
              ? const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : Switch(
                  key: const Key('example-data-switch'),
                  value: on,
                  onChanged: _busy ? null : (value) => unawaited(_set(value)),
                ),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: LinearProgressIndicator(),
          ),
        if (_justOn && on == true)
          const SettingsMessage(
            'Added. Echo is reading the conversations: in a minute or two they are in '
            'Today and Memory, with their summaries.',
            key: Key('example-data-reading'),
          ),
        if (_error case final error?) SettingsMessage(error, error: true),
      ],
    );
  }
}
