import 'package:flutter/material.dart';

import '../models/action_models.dart';
import '../services/api/api_exception.dart';
import '../services/api/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/panel.dart';

class ActionLogScreen extends StatefulWidget {
  const ActionLogScreen({this.api, super.key});

  /// Injected API (not disposed by the screen); a private one is created when
  /// omitted.
  final ApiService? api;

  @override
  State<ActionLogScreen> createState() => _ActionLogScreenState();
}

class _ActionLogScreenState extends State<ActionLogScreen> {
  late final ApiService _api = widget.api ?? ApiService();
  List<ActionLogEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (widget.api == null) _api.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _api.getActionLog();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            error is ApiException ? error.message : 'Could not load activity.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: const Text('Activity')),
      body: _body(palette),
    );
  }

  Widget _body(EchoPalette palette) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: palette.text2)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text('No actions yet.', style: TextStyle(color: palette.text2)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _entries.length,
      itemBuilder: (_, i) => PanelListRow(
        index: i,
        count: _entries.length,
        child: _EntryTile(entry: _entries[i]),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final ActionLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final error = entry.error;
    final local = entry.createdAt.toLocal();
    final loc = MaterialLocalizations.of(context);
    final stamp = '${loc.formatShortDate(local)} '
        '${loc.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.tool,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
              ),
              Text(stamp, style: TextStyle(fontSize: 12, color: palette.text2)),
            ],
          ),
          if (entry.toolkit.isNotEmpty)
            Text(
              entry.toolkit,
              style: TextStyle(fontSize: 12, color: palette.text2),
            ),
          if (entry.argumentsSummary.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              entry.argumentsSummary,
              style: TextStyle(fontSize: 13, color: palette.text),
            ),
          ],
          if (error != null && error.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(error, style: TextStyle(fontSize: 13, color: palette.red)),
          ],
        ],
      ),
    );
  }
}
