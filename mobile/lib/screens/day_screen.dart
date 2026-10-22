import 'dart:async';

import 'package:flutter/material.dart';

import '../models/memory.dart';
import '../models/today_insights.dart';
import '../services/api/api_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
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
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: Text(dayLabel(widget.day, widget.clock()))),
      body: ListView(
        key: const Key('day-screen'),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          if (_digest case final digest? when digest.summary.isNotEmpty) ...[
            Panel(
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
            const SizedBox(height: 12),
          ],
          DayConversationsPanel(
            conversations: widget.conversations,
            onOpen: (id) => unawaited(_open(id)),
          ),
        ],
      ),
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
    return Scaffold(
      backgroundColor: EchoPalette.of(context).background,
      appBar: AppBar(title: Text(weekLabel(week.weekStart, now))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [WeeklySummarySection(week: week, now: now, expanded: true)],
      ),
    );
  }
}
