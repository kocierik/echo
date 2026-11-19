import 'package:flutter/material.dart';

import '../models/action_models.dart';
import 'today_sections.dart';

/// What Today's card on top shows: only what needs the user. The day itself, the
/// conversation going on and what is coming up are sections of Today.
sealed class TodayMoment {
  const TodayMoment();
}

/// Something to confirm: the action that expires first, and how many more wait.
final class ConfirmMoment extends TodayMoment {
  const ConfirmMoment(this.action, {this.more = 0});

  final PendingAction action;
  final int more;
}

/// The card on top: an action to confirm, the one that expires first; null with none.
///
/// One confirmed or cancelled here stays until the list is reloaded, so its outcome
/// shows.
TodayMoment? pickMoment({required List<PendingAction> pending}) {
  bool waiting(PendingAction a) => a.status == null || a.status == 'pending';
  final waitingActions = pending.where(waiting).toList()
    ..sort((a, b) => (a.expiresAt ?? DateTime(9999)).compareTo(b.expiresAt ?? DateTime(9999)));
  if (waitingActions.isNotEmpty) {
    return ConfirmMoment(waitingActions.first, more: waitingActions.length - 1);
  }
  if (pending.isNotEmpty) return ConfirmMoment(pending.first);
  return null;
}

/// Today's one card at the top: what needs the user.
final class TodayTopCard extends StatelessWidget {
  const TodayTopCard({
    required this.moment,
    required this.busyIds,
    required this.onConfirm,
    required this.onCancel,
    required this.onMore,
    super.key,
  });

  final TodayMoment moment;
  final Set<String> busyIds;
  final void Function(PendingAction action) onConfirm;
  final void Function(PendingAction action) onCancel;

  /// "+N more": every action waiting.
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('today-top-card'),
      padding: const EdgeInsets.only(bottom: 4),
      child: switch (moment) {
        ConfirmMoment(:final action, :final more) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NeedsYouSection(
                actions: [action],
                busyIds: busyIds,
                onConfirm: onConfirm,
                onCancel: onCancel,
              ),
              if (more > 0)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    // The button's own 12 pt + 20 = 32, where the group's text starts
                    padding: const EdgeInsets.only(left: 20),
                    child: TextButton(
                      key: const Key('needs-you-more'),
                      onPressed: onMore,
                      child: Text('+$more more'),
                    ),
                  ),
                ),
            ],
          ),
      },
    );
  }
}
