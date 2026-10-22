/// The quick follow-ups under a photo's answer in Ask. What they send is in the
/// language the user speaks (Echo answers in it); their labels are the app's English.
library;

import 'formatting.dart';

const _weekdays = {
  'en': ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'],
  'it': ['lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì', 'sabato', 'domenica'],
};

const _months = {
  'en': [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ],
  'it': [
    'gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno',
    'luglio', 'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre',
  ],
};

/// "Translate it": the photo's text into the language the user speaks.
String translateRequest(String language) => language == 'it' ? 'Traducilo' : 'Translate it';

/// "Ricordamelo giovedì 23 ottobre alle 9:00": the agent makes the reminder of what the
/// photo showed. Midnight is a day without a time.
String reminderRequest(DateTime when, String language) {
  final it = language == 'it';
  final names = it ? 'it' : 'en';
  final day = '${_weekdays[names]![when.weekday - 1]} ${when.day} ${_months[names]![when.month - 1]}';
  final hasTime = when.hour != 0 || when.minute != 0;
  final time = '${when.hour}:${when.minute.toString().padLeft(2, '0')}';
  if (it) return hasTime ? 'Ricordamelo $day alle $time' : 'Ricordamelo $day';
  return hasTime ? 'Remind me on $day at $time' : 'Remind me on $day';
}

/// The chip: "Remind me at 18:00" today, "Remind me tomorrow", a weekday within the
/// week, else "Remind me Nov 23".
String reminderChipLabel(DateTime when, DateTime now) {
  final days = dayOf(when).difference(dayOf(now)).inDays;
  if (days <= 0) return 'Remind me at ${formatTime(when)}';
  if (days == 1) return 'Remind me tomorrow';
  if (days < 7) return 'Remind me ${_weekdays['en']![when.weekday - 1]}';
  return 'Remind me ${shortDate(when)}';
}
