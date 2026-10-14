/// Display formatting shared by the memory screens: one place for times, days,
/// durations and speaker names so every screen says the same thing.
library;

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "09:05", in the device's local time.
String formatTime(DateTime value) {
  final local = value.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// "Oct 14".
String shortDate(DateTime value) => '${_months[value.month - 1]} ${value.day}';

DateTime dayOf(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// "Today", "Yesterday", "Tomorrow", "Mon, Oct 13" (with the year when it is
/// not this year).
String dayLabel(DateTime day, DateTime now) {
  final date = dayOf(day);
  final today = dayOf(now);
  final difference = today.difference(date).inDays;
  if (difference == 0) return 'Today';
  if (difference == 1) return 'Yesterday';
  if (difference == -1) return 'Tomorrow';
  final label = '${_weekdays[date.weekday - 1]}, ${shortDate(date)}';
  return date.year == today.year ? label : '$label ${date.year}';
}

/// "45 s", "12 min", "1 h 20 min", "3 d 2 h".
String formatDuration(Duration value) {
  final seconds = value.inSeconds;
  if (seconds < 60) return '$seconds s';
  final minutes = value.inMinutes;
  if (minutes < 60) return '$minutes min';
  final hours = value.inHours;
  if (hours < 24) {
    final rest = minutes - hours * 60;
    return rest == 0 ? '$hours h' : '$hours h $rest min';
  }
  final days = value.inDays;
  final restHours = hours - days * 24;
  return restHours == 0 ? '$days d' : '$days d $restHours h';
}

final _speakerPrefix = RegExp(r'^\[(Tu|Altri|You|Others?)\]\s*', caseSensitive: false);

/// A transcript line without the "[Tu]"/"[Others]" prefix the backend writes.
String cleanTranscript(String text) => text.replaceFirst(_speakerPrefix, '').trim();

/// "You", "Other" or "Unknown" for a speaker label (self/other/unknown).
String speakerName(String? speaker) {
  return switch (speaker?.toLowerCase()) {
    'self' => 'You',
    'other' => 'Other',
    _ => 'Unknown',
  };
}
