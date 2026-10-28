import 'package:flutter/material.dart';

import '../models/action_models.dart';
import '../models/memory.dart';
import '../models/today_insights.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import 'conversation_card.dart';
import 'panel.dart';
import 'today_sections.dart';

/// What Today's one top card shows: the first of these that applies.
sealed class TodayMoment {
  const TodayMoment();
}

/// Something to confirm: the action that expires first, and how many more wait.
final class ConfirmMoment extends TodayMoment {
  const ConfirmMoment(this.action, {this.more = 0});

  final PendingAction action;
  final int more;
}

/// An event in the next hour, with what was said last time.
final class ComingUpMoment extends TodayMoment {
  const ComingUpMoment(this.comingUp);

  final ComingUp comingUp;
}

/// The conversation going on now: how long, who, the last line heard.
final class NowMoment extends TodayMoment {
  const NowMoment(this.conversation, {this.lastLine});

  final ConversationCard conversation;
  final String? lastLine;
}

/// "So far today": the main conversations in a line, and three counts.
final class SoFarMoment extends TodayMoment {
  const SoFarMoment({
    required this.line,
    required this.conversations,
    required this.talked,
    required this.people,
  });

  final String line;
  final int conversations;
  final Duration talked;
  final int people;
}

/// The top card for the moment: an action to confirm, then an event within the hour,
/// then the conversation going on, then the day so far; null with none of them.
///
/// The actions waiting come first by expiry; one confirmed or cancelled here stays
/// until the list is reloaded, so its outcome shows.
TodayMoment? pickMoment({
  required List<PendingAction> pending,
  ComingUp? comingUp,
  ConversationCard? open,
  String? lastLine,
  required List<ConversationCard> today,
  required DateTime now,
}) {
  bool waiting(PendingAction a) => a.status == null || a.status == 'pending';
  final waitingActions = pending.where(waiting).toList()
    ..sort((a, b) => (a.expiresAt ?? DateTime(9999)).compareTo(b.expiresAt ?? DateTime(9999)));
  if (waitingActions.isNotEmpty) {
    return ConfirmMoment(waitingActions.first, more: waitingActions.length - 1);
  }
  if (pending.isNotEmpty) return ConfirmMoment(pending.first);
  if (comingUp != null) return ComingUpMoment(comingUp);
  if (open != null) return NowMoment(open, lastLine: lastLine);
  final finished = today.where((c) => !c.isOpen).toList();
  if (finished.isEmpty) return null;
  final people = {for (final c in finished) ...c.people};
  return SoFarMoment(
    line: soFarLine(finished),
    conversations: finished.length,
    talked: finished.fold(Duration.zero, (sum, c) => sum + c.duration),
    people: people.length,
  );
}

/// "Good morning", "Good afternoon" or "Good evening".
String greeting(DateTime now) => now.hour >= 5 && now.hour < 12
    ? 'Good morning'
    : now.hour >= 12 && now.hour < 18
        ? 'Good afternoon'
        : 'Good evening';

/// "Stand-up with Marco, Lunch with Ada, The Atlas call.": the three longest
/// conversations with a title, in the order of the day.
String soFarLine(List<ConversationCard> today) {
  final titled = today.where((c) => c.title != null).toList()
    ..sort((a, b) => b.duration.compareTo(a.duration));
  final main = titled.take(3).toList()..sort((a, b) => a.startedAt.compareTo(b.startedAt));
  if (main.isEmpty) return '';
  return '${main.map((c) => c.title).join(', ')}.';
}

/// Today's one card at the top, drawn for its moment.
final class TodayTopCard extends StatelessWidget {
  const TodayTopCard({
    required this.moment,
    required this.now,
    required this.busyIds,
    required this.onConfirm,
    required this.onCancel,
    required this.onMore,
    required this.onOpenConversation,
    super.key,
  });

  final TodayMoment moment;
  final DateTime now;
  final Set<String> busyIds;
  final void Function(PendingAction action) onConfirm;
  final void Function(PendingAction action) onCancel;

  /// "+N more": every action waiting.
  final VoidCallback onMore;
  final void Function(ConversationCard conversation) onOpenConversation;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('today-top-card'),
      padding: const EdgeInsets.only(bottom: 12),
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
                  child: TextButton(
                    key: const Key('needs-you-more'),
                    onPressed: onMore,
                    child: Text('+$more more'),
                  ),
                ),
            ],
          ),
        ComingUpMoment(:final comingUp) => _ComingUpCard(comingUp: comingUp),
        NowMoment(:final conversation, :final lastLine) => _NowCard(
            conversation: conversation,
            lastLine: lastLine,
            now: now,
            onTap: () => onOpenConversation(conversation),
          ),
        final SoFarMoment soFar => _SoFarCard(moment: soFar),
      },
    );
  }
}

final class _Overline extends StatelessWidget {
  const _Overline(this.text, {this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: color ?? EchoPalette.of(context).text2,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
          ),
    );
  }
}

final class _ComingUpCard extends StatelessWidget {
  const _ComingUpCard({required this.comingUp});

  final ComingUp comingUp;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Panel(
      key: const Key('coming-up'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Overline('COMING UP · ${formatTime(comingUp.start)}'),
          const SizedBox(height: 4),
          Text(comingUp.title, style: textTheme.titleMedium),
          if (comingUp.recap case final recap?) ...[
            const SizedBox(height: 3),
            Text(recap, style: textTheme.bodyMedium?.copyWith(color: palette.text2)),
          ],
        ],
      ),
    );
  }
}

final class _NowCard extends StatelessWidget {
  const _NowCard({
    required this.conversation,
    required this.lastLine,
    required this.now,
    required this.onTap,
  });

  final ConversationCard conversation;
  final String? lastLine;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final going = now.difference(conversation.startedAt);
    final minutes = going.isNegative ? Duration.zero : going;
    final people = conversation.people;
    return Panel(
      key: const Key('now-card'),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Overline(
            minutes.inMinutes > 0 ? 'NOW · ${formatDuration(minutes).toUpperCase()}' : 'NOW',
            color: palette.liveText,
          ),
          if (people.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('with ${people.take(3).join(', ')}', style: textTheme.bodySmall),
          ],
          if (conversation.title case final title?) ...[
            const SizedBox(height: 4),
            Text(title, style: textTheme.titleMedium),
          ],
          if (lastLine case final line?) ...[
            const SizedBox(height: 6),
            Text(
              '"…$line…"',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyMedium?.copyWith(
                color: palette.text2,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (conversation.title == null && lastLine == null) ...[
            const SizedBox(height: 4),
            Text(conversationTitle(conversation), style: textTheme.titleMedium),
          ],
        ],
      ),
    );
  }
}

final class _SoFarCard extends StatelessWidget {
  const _SoFarCard({required this.moment});

  final SoFarMoment moment;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final counts = [
      moment.conversations == 1 ? '1 conversation' : '${moment.conversations} conversations',
      if (moment.talked.inMinutes > 0) '${formatDuration(moment.talked)} of talk',
      if (moment.people > 0) moment.people == 1 ? '1 person' : '${moment.people} people',
    ];
    return Panel(
      key: const Key('so-far-today'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Overline('SO FAR TODAY'),
          if (moment.line.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              moment.line,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyLarge,
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [for (final count in counts) _Count(count)],
          ),
        ],
      ),
    );
  }
}

final class _Count extends StatelessWidget {
  const _Count(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: palette.tint,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: Theme.of(context).textTheme.labelMedium),
    );
  }
}
