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

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final label = statusLabel(action.status);
    return Container(
      key: Key('action-card-${action.id}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surface2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(action.summary, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 10),
          if (_pending)
            Row(
              children: [
                FilledButton(
                  key: Key('action-confirm-${action.id}'),
                  onPressed: busy ? null : onConfirm,
                  child: const Text('Confirm'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: Key('action-cancel-${action.id}'),
                  onPressed: busy ? null : onCancel,
                  child: const Text('Cancel'),
                ),
                if (busy) ...[
                  const SizedBox(width: 12),
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            )
          else if (label != null)
            Text(
              label,
              key: Key('action-status-${action.id}'),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: action.status == 'executed'
                        ? palette.green
                        : action.status == 'failed'
                            ? palette.red
                            : palette.text2,
                  ),
            ),
        ],
      ),
    );
  }
}
