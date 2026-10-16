import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/api/api_service.dart';
import '../../theme/app_theme.dart';

/// The setup for a connected app: its key (shown once), the address, and the lines to
/// paste in Claude Code or Cursor.
final class ConnectAppSheet extends StatelessWidget {
  const ConnectAppSheet({required this.app, super.key});

  final ConnectedAppKey app;

  static String claudeCode(ConnectedAppKey app) =>
      'claude mcp add --transport http echo ${app.mcpUrl} '
      '--header "Authorization: Bearer ${app.apiKey}"';

  static String cursor(ConnectedAppKey app) =>
      '{"mcpServers": {"echo": {"url": "${app.mcpUrl}", '
      '"headers": {"Authorization": "Bearer ${app.apiKey}"}}}}';

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${app.name} can read your memory', style: textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              "It can search your conversations, people, tasks and summaries. It can't "
              'change or delete anything.',
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            _Block(label: 'Key', value: app.apiKey, copy: 'Copy key'),
            Text(
              "You won't see this key again.",
              style: textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            _Block(label: 'Address', value: app.mcpUrl, copy: 'Copy address'),
            _Block(label: 'Claude Code', value: claudeCode(app), copy: 'Copy'),
            _Block(label: 'Cursor (mcp.json)', value: cursor(app), copy: 'Copy'),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _Block extends StatelessWidget {
  const _Block({required this.label, required this.value, required this.copy});

  final String label;
  final String value;
  final String copy;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: textTheme.labelLarge)),
              TextButton(
                onPressed: () {
                  unawaited(Clipboard.setData(ClipboardData(text: value)));
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(content: Text('$label copied.')),
                  );
                },
                child: Text(copy),
              ),
            ],
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: palette.surface2,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              value,
              style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
