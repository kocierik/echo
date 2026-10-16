import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/device_command.dart';
import '../api/device_api.dart';
import '../device/phone_words.dart';
import 'phone_calendar.dart';

/// Which of the iPhone's apps the user turned on for Echo (off by default).
final class PhoneAppChoices {
  PhoneAppChoices(this._preferences);

  static String key(PhoneApp app) => 'phone_app_${app.name}';

  final SharedPreferences _preferences;

  bool isOn(PhoneApp app) => _preferences.getBool(key(app)) ?? false;

  Future<void> set(PhoneApp app, bool on) => _preferences.setBool(key(app), on);
}

/// Reminders and Calendar on this iPhone, for Echo.
///
/// The user turns them on in Settings → Automations → On this iPhone (iOS asks for
/// access then); the server is told which are on, now and on every wake. Echo's requests
/// ("remind me…", "what do I have tomorrow?") reach the app as `phone_action` commands:
/// [handle] runs one with EventKit and posts what it did. The calendar's next events also
/// go with the notifications refresh, for briefings before those meetings.
final class PhoneActionsService {
  PhoneActionsService({
    required PhoneCalendar calendar,
    required PhoneAppChoices choices,
    required DeviceCommandsApi commands,
    required PhoneAppsApi server,
    DateTime Function()? clock,
  })  : _calendar = calendar,
        _choices = choices,
        _commands = commands,
        _server = server,
        _clock = clock ?? DateTime.now;

  static const maxRange = Duration(days: 31);
  static const maxItems = 50;

  /// The server keeps the choice for days: on wakes (every uploaded segment) it is
  /// told again at most this often.
  static const reportInterval = Duration(hours: 6);

  final PhoneCalendar _calendar;
  final PhoneAppChoices _choices;
  final DeviceCommandsApi _commands;
  final PhoneAppsApi _server;
  final DateTime Function() _clock;
  DateTime? _reportedAt;

  bool isOn(PhoneApp app) => _choices.isOn(app);

  Future<PhoneAccess> access(PhoneApp app) => _calendar.access(app);

  /// Turns an app on (asking iOS for access when needed) or off, and tells the server.
  /// Returns the access: an app iOS refuses stays off.
  Future<PhoneAccess> setOn(PhoneApp app, bool on) async {
    var access = await _calendar.access(app);
    if (on && access == PhoneAccess.notAsked) {
      access = await _calendar.requestAccess(app) ? PhoneAccess.granted : PhoneAccess.denied;
    }
    await _choices.set(app, on && access == PhoneAccess.granted);
    await report(force: true);
    return access;
  }

  /// Tells the server which apps Echo may use: on, and allowed by iOS. At most every
  /// [reportInterval] unless [force]d. Never throws.
  Future<void> report({bool force = false}) async {
    final last = _reportedAt;
    if (!force && last != null && _clock().difference(last) < reportInterval) return;
    try {
      await _server.reportPhoneApps(
        reminders: await _usable(PhoneApp.reminders),
        calendar: await _usable(PhoneApp.calendar),
      );
      _reportedAt = _clock();
    } catch (error) {
      debugPrint('[Phone] could not report the apps: $error');
    }
  }

  Future<bool> _usable(PhoneApp app) async =>
      _choices.isOn(app) && await _calendar.access(app) == PhoneAccess.granted;

  /// Runs a command and posts what it did. Never throws.
  Future<void> handle(PhoneActionCommand command) async {
    final result = await run(command.tool, command.arguments);
    try {
      await _commands.sendCommandResult(command.id, result);
    } catch (error) {
      // Echo waits a few seconds and then tells the user to check the app
      debugPrint('[Phone] could not send the result of ${command.tool}: $error');
    }
  }

  /// What [tool] did on this iPhone: `{"ok": true, "data": …}` or
  /// `{"ok": false, "error": …}`, an error the model can tell the user.
  Future<Map<String, Object?>> run(
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    final app = switch (tool.split('_').first) {
      'APPLEREMINDERS' => PhoneApp.reminders,
      'APPLECALENDAR' => PhoneApp.calendar,
      _ => null,
    };
    if (app == null) return _error('Unknown tool: $tool');
    final name = app == PhoneApp.reminders ? 'Reminders' : 'Calendar';
    if (!_choices.isOn(app)) {
      return _error('$name is turned off in Echo (Settings → ${PhoneWords.onThisPhone})');
    }
    if (await _calendar.access(app) != PhoneAccess.granted) {
      return _error(
          'Echo is not allowed to use $name: allow it in ${PhoneWords.systemSettings} → Echo');
    }
    try {
      return switch (tool) {
        'APPLEREMINDERS_CREATE_REMINDER' => await _createReminder(arguments),
        'APPLEREMINDERS_LIST_REMINDERS' => await _listReminders(arguments),
        'APPLECALENDAR_CREATE_EVENT' => await _createEvent(arguments),
        'APPLECALENDAR_LIST_EVENTS' => await _listEvents(arguments),
        _ => _error('Unknown tool: $tool'),
      };
    } on FormatException catch (error) {
      return _error(error.message);
    } on PhoneCalendarException catch (error) {
      return _error(error.message);
    }
  }

  Future<Map<String, Object?>> _createReminder(Map<String, dynamic> arguments) async {
    final due = _when(arguments['due'], 'due');
    final reminder = await _calendar.createReminder(
      title: _required(arguments, 'title'),
      notes: _optional(arguments['notes']),
      due: due?.at,
      dueHasTime: due?.hasTime ?? false,
      list: _optional(arguments['list']),
    );
    return _ok(_reminderJson(reminder));
  }

  Future<Map<String, Object?>> _listReminders(Map<String, dynamic> arguments) async {
    final query = _optional(arguments['query'])?.toLowerCase();
    final reminders = (await _calendar.openReminders(
      dueBefore: _when(arguments['due_before'], 'due_before')?.at,
    ))
        .where((r) => query == null || r.title.toLowerCase().contains(query))
        .toList()
      ..sort((a, b) {
        if (a.due == null || b.due == null) return a.due == null ? 1 : -1;
        return a.due!.compareTo(b.due!);
      });
    return _ok({'reminders': reminders.take(maxItems).map(_reminderJson).toList()});
  }

  Future<Map<String, Object?>> _createEvent(Map<String, dynamic> arguments) async {
    final start = _when(arguments['start'], 'start') ??
        (throw const FormatException('start is required'));
    final allDay = !start.hasTime;
    final end = _when(arguments['end'], 'end')?.at ??
        (allDay ? start.at : start.at.add(const Duration(hours: 1)));
    if (end.isBefore(start.at)) {
      throw const FormatException('end must be after start');
    }
    final event = await _calendar.createEvent(
      title: _required(arguments, 'title'),
      start: start.at,
      end: end,
      allDay: allDay,
      location: _optional(arguments['location']),
      notes: _optional(arguments['notes']),
      calendar: _optional(arguments['calendar']),
    );
    return _ok(_eventJson(event));
  }

  Future<Map<String, Object?>> _listEvents(Map<String, dynamic> arguments) async {
    final start = _when(arguments['start'], 'start') ??
        (throw const FormatException('start is required'));
    final end = _when(arguments['end'], 'end') ??
        (throw const FormatException('end is required'));
    // A day given as the end means the whole of that day
    final until = end.hasTime ? end.at : end.at.add(const Duration(days: 1));
    if (!until.isAfter(start.at)) {
      throw const FormatException('end must be after start');
    }
    if (until.difference(start.at) > maxRange) {
      throw const FormatException('at most 31 days at a time');
    }
    final query = _optional(arguments['query'])?.toLowerCase();
    final events = (await _calendar.events(start: start.at, end: until))
        .where((e) => query == null || e.title.toLowerCase().contains(query))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return _ok({'events': events.take(maxItems).map(_eventJson).toList()});
  }

  /// The calendar's events of the next [within], for the notifications refresh: what
  /// the server needs to brief before a meeting. Empty when the calendar is off.
  Future<List<Map<String, Object?>>> upcomingEvents({
    Duration within = const Duration(hours: 36),
  }) async {
    try {
      if (!await _usable(PhoneApp.calendar)) return const [];
      final now = _clock();
      final events = await _calendar.events(start: now, end: now.add(within));
      return [
        for (final event in events)
          {
            // Each occurrence of a repeating event is its own meeting
            'id': '${event.id}@${event.start.millisecondsSinceEpoch}',
            'title': event.title,
            'start': event.start.toUtc().toIso8601String(),
            'all_day': event.allDay,
            'notes': event.notes,
            'attendees': [
              for (final guest in event.attendees)
                {'name': guest.name, 'email': guest.email},
            ],
          },
      ];
    } catch (error) {
      debugPrint('[Phone] could not read the calendar: $error');
      return const [];
    }
  }

  Map<String, Object?> _reminderJson(PhoneReminder reminder) => {
        'id': reminder.id,
        'title': reminder.title,
        'list': reminder.list,
        if (reminder.notes != null) 'notes': reminder.notes,
        'due': reminder.due == null
            ? null
            : _local(reminder.due!, withTime: reminder.dueHasTime),
      };

  Map<String, Object?> _eventJson(PhoneEvent event) => {
        'id': event.id,
        'title': event.title,
        'start': _local(event.start, withTime: !event.allDay),
        'end': _local(event.end, withTime: !event.allDay),
        'all_day': event.allDay,
        'calendar': event.calendar,
        if (event.location != null) 'location': event.location,
        if (event.notes != null) 'notes': event.notes,
        if (event.attendees.isNotEmpty)
          'attendees': [
            for (final guest in event.attendees)
              guest.name.isNotEmpty ? guest.name : guest.email,
          ],
      };
}

Map<String, Object?> _ok(Object? data) => {'ok': true, 'data': data};

Map<String, Object?> _error(String message) => {'ok': false, 'error': message};

String _required(Map<String, dynamic> arguments, String key) =>
    _optional(arguments[key]) ?? (throw FormatException('$key is required'));

String? _optional(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

final _dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// "2026-10-16T18:00" (local), with an offset, or "2026-10-16" (a day, no time).
({DateTime at, bool hasTime})? _when(Object? value, String key) {
  final text = _optional(value);
  if (text == null) return null;
  if (_dateOnly.hasMatch(text)) {
    final day = DateTime.tryParse(text);
    if (day == null) throw FormatException('$key is not a date: $text');
    return (at: DateTime(day.year, day.month, day.day), hasTime: false);
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null) throw FormatException('$key is not a date and time: $text');
  return (at: parsed.isUtc ? parsed.toLocal() : parsed, hasTime: true);
}

/// "2026-10-16T18:00", or "2026-10-16" without the time.
String _local(DateTime value, {required bool withTime}) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final day = '${local.year}-${two(local.month)}-${two(local.day)}';
  return withTime ? '${day}T${two(local.hour)}:${two(local.minute)}' : day;
}
