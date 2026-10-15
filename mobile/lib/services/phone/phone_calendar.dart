import 'package:flutter/services.dart';

/// The iPhone's apps Echo can use.
enum PhoneApp { reminders, calendar }

/// Whether Echo may use an app: allowed, refused (in iOS Settings), not asked yet, or not
/// on this device (no EventKit: Android, tests).
enum PhoneAccess { granted, denied, notAsked, unavailable }

/// A reminder of the Reminders app.
final class PhoneReminder {
  const PhoneReminder({
    required this.id,
    required this.title,
    required this.list,
    this.notes,
    this.due,
    this.dueHasTime = false,
  });

  final String id;
  final String title;
  final String list;
  final String? notes;
  final DateTime? due;

  /// False for a reminder due on a day, without an alert time.
  final bool dueHasTime;
}

/// An event of the Calendar app (any calendar on the iPhone).
final class PhoneEvent {
  const PhoneEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.calendar,
    this.allDay = false,
    this.location,
    this.notes,
    this.attendees = const [],
  });

  final String id;
  final String title;
  final DateTime start;
  final DateTime end;
  final String calendar;
  final bool allDay;
  final String? location;
  final String? notes;

  /// Name and e-mail of each guest (either may be empty).
  final List<({String name, String email})> attendees;
}

/// EventKit as Echo uses it. Implemented in Swift (ios/Runner/EventKit).
abstract interface class PhoneCalendar {
  Future<PhoneAccess> access(PhoneApp app);

  /// Asks iOS for full access (once: later, only iOS Settings can change it).
  Future<bool> requestAccess(PhoneApp app);

  Future<PhoneReminder> createReminder({
    required String title,
    String? notes,
    DateTime? due,
    bool dueHasTime = true,
    String? list,
  });

  /// Open reminders, due before [dueBefore] when given.
  Future<List<PhoneReminder>> openReminders({DateTime? dueBefore});

  Future<PhoneEvent> createEvent({
    required String title,
    required DateTime start,
    required DateTime end,
    bool allDay = false,
    String? location,
    String? notes,
    String? calendar,
  });

  Future<List<PhoneEvent>> events({required DateTime start, required DateTime end});
}

/// [PhoneCalendar] over the "echo/eventkit" channel; dates cross it as epoch ms.
final class EventKitPhoneCalendar implements PhoneCalendar {
  EventKitPhoneCalendar({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('echo/eventkit');

  final MethodChannel _channel;

  @override
  Future<PhoneAccess> access(PhoneApp app) async {
    try {
      final status = await _channel.invokeMethod<String>('access', {'app': app.name});
      return switch (status) {
        'granted' => PhoneAccess.granted,
        'denied' => PhoneAccess.denied,
        'notAsked' => PhoneAccess.notAsked,
        _ => PhoneAccess.unavailable,
      };
    } on MissingPluginException {
      return PhoneAccess.unavailable;
    }
  }

  @override
  Future<bool> requestAccess(PhoneApp app) async {
    try {
      return await _channel.invokeMethod<bool>('requestAccess', {'app': app.name}) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<PhoneReminder> createReminder({
    required String title,
    String? notes,
    DateTime? due,
    bool dueHasTime = true,
    String? list,
  }) async {
    final created = await _call('createReminder', {
      'title': title,
      'notes': notes,
      'due': due?.millisecondsSinceEpoch,
      'dueHasTime': dueHasTime,
      'list': list,
    });
    return _reminder(created as Map);
  }

  @override
  Future<List<PhoneReminder>> openReminders({DateTime? dueBefore}) async {
    final items = await _call('openReminders', {
      'dueBefore': dueBefore?.millisecondsSinceEpoch,
    });
    return [for (final item in items as List) _reminder(item as Map)];
  }

  @override
  Future<PhoneEvent> createEvent({
    required String title,
    required DateTime start,
    required DateTime end,
    bool allDay = false,
    String? location,
    String? notes,
    String? calendar,
  }) async {
    final created = await _call('createEvent', {
      'title': title,
      'start': start.millisecondsSinceEpoch,
      'end': end.millisecondsSinceEpoch,
      'allDay': allDay,
      'location': location,
      'notes': notes,
      'calendar': calendar,
    });
    return _event(created as Map);
  }

  @override
  Future<List<PhoneEvent>> events({
    required DateTime start,
    required DateTime end,
  }) async {
    final items = await _call('events', {
      'start': start.millisecondsSinceEpoch,
      'end': end.millisecondsSinceEpoch,
    });
    return [for (final item in items as List) _event(item as Map)];
  }

  /// A failure on the iPhone (no access, no list…) as a [PhoneCalendarException].
  Future<Object?> _call(String method, Map<String, Object?> arguments) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (error) {
      throw PhoneCalendarException(error.message ?? error.code);
    } on MissingPluginException {
      throw const PhoneCalendarException('Reminders and Calendar are not available here');
    }
  }

  static DateTime? _date(Object? ms) =>
      ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;

  static PhoneReminder _reminder(Map item) => PhoneReminder(
        id: item['id'] as String,
        title: item['title'] as String? ?? '',
        list: item['list'] as String? ?? '',
        notes: item['notes'] as String?,
        due: _date(item['due']),
        dueHasTime: item['dueHasTime'] as bool? ?? false,
      );

  static PhoneEvent _event(Map item) => PhoneEvent(
        id: item['id'] as String,
        title: item['title'] as String? ?? '',
        start: _date(item['start'])!,
        end: _date(item['end'])!,
        calendar: item['calendar'] as String? ?? '',
        allDay: item['allDay'] as bool? ?? false,
        location: item['location'] as String?,
        notes: item['notes'] as String?,
        attendees: [
          for (final guest in (item['attendees'] as List?) ?? const [])
            (
              name: (guest as Map)['name'] as String? ?? '',
              email: guest['email'] as String? ?? '',
            ),
        ],
      );
}

final class PhoneCalendarException implements Exception {
  const PhoneCalendarException(this.message);

  final String message;

  @override
  String toString() => message;
}
