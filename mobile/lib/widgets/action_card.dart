import 'package:flutter/material.dart';

import '../models/action_models.dart';
import '../theme/app_theme.dart';

/// Shows an action Echo wants to perform, with Confirm / Cancel while it is
/// still pending, or a status line once it has been resolved.
final class ActionCard extends StatelessWidget {
  const ActionCard({
    required this.action,
    required this.onConfirm,
    required this.onCancel,
    this.busy = false,
    super.key,
  });

  final PendingAction action;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final bool busy;

  bool get _pending => action.status == null || action.status == 'pending';

  static String? statusLabel(String? status) {
    switch (status) {
      case 'executed':
        return 'Done';
      case 'failed':
        return 'Failed';
      case 'unknown':
        return 'Unknown — check the app';
      case 'cancelled':
        return 'Cancelled';
      case 'expired':
        return 'Expired';
      case 'resolved':
        return 'Already handled';
      default:
        return null;
    }
  }

  /// "Gmail · Voice request" for an action listed outside its chat.
  String? get _caption {
    final parts = [
      if (action.app case final app?) app,
      if (action.source == 'voice') 'Voice request',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final label = statusLabel(action.status);
    return Container(
      key: Key('action-card-${action.id}'),
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(AppTheme.tileRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_caption case final caption?)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(caption, style: Theme.of(context).textTheme.labelSmall),
            ),
          Text(
            action.summary,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          if (_pending)
            // Wraps on narrow screens with large text instead of overflowing
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(
                  key: Key('action-confirm-${action.id}'),
                  onPressed: busy ? null : onConfirm,
                  child: const Text('Confirm'),
                ),
                TextButton(
                  key: Key('action-cancel-${action.id}'),
                  onPressed: busy ? null : onCancel,
                  child: const Text('Cancel'),
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            )
          else if (label != null)
            Text(
              label,
              key: Key('action-status-${action.id}'),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: switch (action.status) {
                      'executed' => palette.green,
                      'failed' => palette.red,
                      'unknown' => palette.amber,
                      _ => palette.text2,
                    },
                  ),
            ),
        ],
      ),
    );
  }
}
