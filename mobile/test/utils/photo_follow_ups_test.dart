import 'package:echo_app/utils/photo_follow_ups.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A Tuesday afternoon
  final now = DateTime(2026, 10, 20, 15, 30);

  test('Translate it, in the language the user speaks', () {
    expect(translateRequest('it'), 'Traducilo');
    expect(translateRequest('en'), 'Translate it');
    expect(translateRequest('de'), 'Translate it');
  });

  test('the reminder is asked in the user language, with the day and time', () {
    final thursday = DateTime(2026, 10, 22, 9);
    expect(reminderRequest(thursday, 'it'), 'Ricordamelo giovedì 22 ottobre alle 9:00');
    expect(reminderRequest(thursday, 'en'), 'Remind me on Thursday 22 October at 9:00');
    // A day without a time
    expect(reminderRequest(DateTime(2026, 11, 2), 'it'), 'Ricordamelo lunedì 2 novembre');
    expect(reminderRequest(DateTime(2026, 11, 2), 'en'), 'Remind me on Monday 2 November');
  });

  test('the chip says when, briefly', () {
    expect(reminderChipLabel(DateTime(2026, 10, 20, 18), now), 'Remind me at 18:00');
    expect(reminderChipLabel(DateTime(2026, 10, 21, 9), now), 'Remind me tomorrow');
    expect(reminderChipLabel(DateTime(2026, 10, 22, 9), now), 'Remind me Thursday');
    expect(reminderChipLabel(DateTime(2026, 11, 23, 9), now), 'Remind me Nov 23');
  });
}
