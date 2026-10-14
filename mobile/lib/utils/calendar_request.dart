import '../models/memory.dart';

/// What Ask is told to add an extracted event to Google Calendar, with every
/// detail Echo knows (the agent asks for a Confirm when people are invited).
String calendarRequest(MemoryEntity event) {
  final date = event.eventDate;
  final time = event.eventTime;
  final minutes = event.metadata['duration_minutes'];
  final location = event.metadata['location'];
  return [
    'Add "${event.name}" to my Google Calendar',
    if (date != null && date.isNotEmpty) ' on $date',
    if (time != null && time.isNotEmpty) ' at $time',
    if (minutes is num && minutes > 0) ' for ${minutes.toInt()} minutes',
    if (location is String && location.trim().isNotEmpty) ', location: ${location.trim()}',
    '.',
  ].join();
}
