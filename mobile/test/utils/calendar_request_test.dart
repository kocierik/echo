import 'package:echo_app/models/memory.dart';
import 'package:echo_app/utils/calendar_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('says every detail Echo knows', () {
    const event = MemoryEntity(
      id: 'e1',
      type: 'event',
      name: 'Dentista',
      metadata: {
        'event_date': '2026-10-16',
        'event_time': '15:00',
        'duration_minutes': 45,
        'location': ' Via Roma 3 ',
      },
    );

    expect(
      calendarRequest(event),
      'Add "Dentista" to my Google Calendar on 2026-10-16 at 15:00 for 45 minutes, '
      'location: Via Roma 3.',
    );
  });

  test('leaves out what is unknown', () {
    const event = MemoryEntity(id: 'e1', type: 'event', name: 'Atlas launch');

    expect(calendarRequest(event), 'Add "Atlas launch" to my Google Calendar.');
  });
}
