import 'package:echo_app/utils/chat_suggestions.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

void main() {
  final now = DateTime(2026, 10, 14, 18);

  test('nothing recent falls back to the defaults', () {
    expect(chatSuggestions(const [], now), defaultChatSuggestions);
    expect(
      chatSuggestions([card('old', startedAt: DateTime(2026, 10, 1))], now),
      defaultChatSuggestions,
    );
  });

  test('suggests the latest conversation, the most present person and today', () {
    final suggestions = chatSuggestions([
      card('live', startedAt: DateTime(2026, 10, 14, 17), title: null, isOpen: true,
          people: const ['Marco']),
      card('lunch', startedAt: DateTime(2026, 10, 14, 12), title: 'Lunch with Ada',
          people: const ['Ada', 'Marco']),
      card('standup', startedAt: DateTime(2026, 10, 13, 9), title: 'Standup',
          people: const ['Luca']),
    ], now);

    expect(suggestions, [
      'Summarize "Lunch with Ada".',
      'What is still open with Marco?',
      'What did I decide today?',
    ]);
  });

  test('only yesterday asks about yesterday and fills up with defaults', () {
    final suggestions = chatSuggestions([
      card('y', startedAt: DateTime(2026, 10, 13, 9), title: 'Standup', people: const []),
    ], now);

    expect(suggestions, [
      'Summarize "Standup".',
      'What happened yesterday?',
      'What did I decide today?',
    ]);
  });
}
