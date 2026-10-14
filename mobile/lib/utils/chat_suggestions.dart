import '../models/memory.dart';
import 'formatting.dart';

/// Used when there is nothing recent to suggest from.
const defaultChatSuggestions = [
  'What did I decide today?',
  'Summarize my latest conversation.',
  'What tasks did I mention this week?',
];

/// Up to three questions about what is in memory right now, from the most recent
/// conversations (newest first): the latest one, the person who comes up most,
/// and the day. Falls back to [defaultChatSuggestions].
List<String> chatSuggestions(List<ConversationCard> recent, DateTime now) {
  final today = dayOf(now);
  final lastTwoDays = recent
      .where((c) => today.difference(dayOf(c.startedAt)).inDays <= 1)
      .toList();
  if (lastTwoDays.isEmpty) return defaultChatSuggestions;

  final suggestions = <String>[];
  final titled = lastTwoDays.where((c) => c.title != null && !c.isOpen);
  if (titled.isNotEmpty) suggestions.add('Summarize "${titled.first.title}".');

  final mentions = <String, int>{};
  for (final c in lastTwoDays) {
    for (final name in c.people) {
      mentions[name] = (mentions[name] ?? 0) + 1;
    }
  }
  if (mentions.isNotEmpty) {
    final person = mentions.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    suggestions.add('What is still open with $person?');
  }

  final talkedToday = lastTwoDays.any((c) => dayOf(c.startedAt) == today);
  suggestions.add(talkedToday ? 'What did I decide today?' : 'What happened yesterday?');

  for (final fallback in defaultChatSuggestions) {
    if (suggestions.length >= 3) break;
    if (!suggestions.contains(fallback)) suggestions.add(fallback);
  }
  return suggestions.take(3).toList();
}
