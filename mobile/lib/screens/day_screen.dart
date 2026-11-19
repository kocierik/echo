import 'dart:async';

import 'package:flutter/material.dart';

import '../models/memory.dart';
import '../models/today_insights.dart';
import '../services/api/api_service.dart';
import '../utils/formatting.dart';
import '../widgets/echo_large_title.dart';
import '../widgets/memory_sections.dart';
import '../widgets/panel.dart';
import '../widgets/summary_sections.dart';
import 'conversation_detail_screen.dart';
import 'navigation.dart';

/// A day, opened from Today: its digest (written overnight) at the top, then every
/// conversation of the day.
final class DayScreen extends StatefulWidget {
  const DayScreen({
    required this.day,
    required this.conversations,
    required this.api,
    this.onAsk,
    this.openConversation,
    this.clock = DateTime.now,
    super.key,
  });

  final DateTime day;

  /// The day's conversations, newest first.
  final List<ConversationCard> conversations;
  final MemoryApi api;
  final AskCallback? onAsk;
  final ConversationOpener? openConversation;
  final DateTime Function() clock;

  @override
  State<DayScreen> createState() => _DayScreenState();
}

final class _DayScreenState extends State<DayScreen> {
  DailySummary? _digest;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDigest());
  }

  /// Optional: a day without one (today, or a quiet day) shows only its conversations.
  Future<void> _loadDigest() async {
    final api = widget.api;
    if (api is! DigestApi) return;
    try {
      final digest = await (api as DigestApi).getDigest(widget.day);
      if (mounted) setState(() => _digest = digest);
    } catch (_) {}
  }

  Future<void> _open(String id) async {
    final opener = widget.openConversation;
    if (opener != null) {
      await opener(context, id);
      return;
    }
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => ConversationDetailScreen(
        conversationId: id,
        api: widget.api,
        onAsk: widget.onAsk,
        clock: widget.clock,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return EchoLargeTitlePage(
      key: const Key('day-screen'),
      title: dayLabel(widget.day, widget.clock()),
      slivers: [
        if (_digest case final digest? when digest.summary.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Panel(
                key: const Key('day-digest'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const PanelHeader(title: 'The day'),
                    const SizedBox(height: 6),
                    Text(digest.summary, style: textTheme.bodyMedium),
                  ],
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: DayConversationsPanel(
            conversations: widget.conversations,
            onOpen: (id) => unawaited(_open(id)),
          ),
        ),
      ],
    );
  }
}

/// The week's summary, opened from "This week" in Today's "Earlier".
final class WeekScreen extends StatelessWidget {
  const WeekScreen({required this.week, required this.now, super.key});

  final WeeklySummary week;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return EchoLargeTitlePage(
      title: weekLabel(week.weekStart, now),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: WeeklySummarySection(week: week, now: now, expanded: true),
          ),
        ),
      ],
    );
  }
}
