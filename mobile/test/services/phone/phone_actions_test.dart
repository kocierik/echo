import 'package:echo_app/models/device_command.dart';
import 'package:echo_app/services/api/device_api.dart';
import 'package:echo_app/services/phone/phone_actions.dart';
import 'package:echo_app/services/phone/phone_calendar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late _FakeCalendar calendar;
  late _FakeServer server;
  late PhoneAppChoices choices;
  late PhoneActionsService service;
  var now = DateTime(2026, 10, 15, 9);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    calendar = _FakeCalendar();
    server = _FakeServer();
    choices = PhoneAppChoices(await SharedPreferences.getInstance());
    now = DateTime(2026, 10, 15, 9);
    service = PhoneActionsService(
      calendar: calendar,
      choices: choices,
      commands: server,
      server: server,
      clock: () => now,
    );
  });

  Future<void> turnOn(PhoneApp app) async {
    calendar.accessOf[app] = PhoneAccess.granted;
    await choices.set(app, true);
  }

  group('turning an app on', () {
    test('asks iOS once, keeps the choice and tells the server', () async {
      calendar.accessOf[PhoneApp.reminders] = PhoneAccess.notAsked;
      calendar.grant = true;

      final access = await service.setOn(PhoneApp.reminders, true);

      expect(access, PhoneAccess.granted);
      expect(calendar.requests, [PhoneApp.reminders]);
      expect(service.isOn(PhoneApp.reminders), isTrue);
      expect(server.reports, [(reminders: true, calendar: false)]);
    });

    test('an app iOS refuses stays off', () async {
      calendar.accessOf[PhoneApp.calendar] = PhoneAccess.denied;

      final access = await service.setOn(PhoneApp.calendar, true);

      expect(access, PhoneAccess.denied);
      expect(calendar.requests, isEmpty);
      expect(service.isOn(PhoneApp.calendar), isFalse);
      expect(server.reports.single.calendar, isFalse);
    });

    test('the server hears it again at most every six hours, unless forced', () async {
      await turnOn(PhoneApp.reminders);
      await service.report();
      await service.report();
      now = now.add(const Duration(hours: 7));
      await service.report();
      await service.report(force: true);

      expect(server.reports, hasLength(3));
    });

    test('access taken back in iOS Settings is not reported as on', () async {
      await turnOn(PhoneApp.reminders);
      calendar.accessOf[PhoneApp.reminders] = PhoneAccess.denied;

      await service.report(force: true);

      expect(server.reports.single.reminders, isFalse);
    });
  });

  group('reminders', () {
    setUp(() => turnOn(PhoneApp.reminders));

    test('one with a time alerts then; one with a day has no time', () async {
      final timed = await service.run('APPLEREMINDERS_CREATE_REMINDER', {
        'title': ' Comprare il latte ',
        'due': '2026-10-16T18:00',
        'notes': '',
      });
      final daily = await service.run('APPLEREMINDERS_CREATE_REMINDER', {
        'title': 'Bollette',
        'due': '2026-10-20',
        'list': 'Casa',
      });

      expect(timed, {
        'ok': true,
        'data': {
          'id': 'r1',
          'title': 'Comprare il latte',
          'list': 'Promemoria',
          'due': '2026-10-16T18:00',
        },
      });
      expect(calendar.created.first, (
        title: 'Comprare il latte',
        notes: null,
        due: DateTime(2026, 10, 16, 18),
        dueHasTime: true,
        list: null,
      ));
      expect((daily['data'] as Map)['due'], '2026-10-20');
      expect(calendar.created.last.dueHasTime, isFalse);
      expect(calendar.created.last.list, 'Casa');
    });

    test('a time with an offset is the same moment on the phone', () async {
      await service.run('APPLEREMINDERS_CREATE_REMINDER', {
        'title': 'Chiamare Ada',
        'due': '2026-10-16T16:00:00Z',
      });

      expect(calendar.created.single.due,
          DateTime.utc(2026, 10, 16, 16).toLocal());
    });

    test('the open ones, soonest first, those without a date last', () async {
      calendar.reminders = [
        const PhoneReminder(id: 'a', title: 'Senza data', list: 'L'),
        PhoneReminder(
            id: 'b', title: 'Dopo', list: 'L', due: DateTime(2026, 10, 18), dueHasTime: false),
        PhoneReminder(
            id: 'c', title: 'Prima', list: 'L', due: DateTime(2026, 10, 16, 9), dueHasTime: true),
      ];

      final result = await service.run('APPLEREMINDERS_LIST_REMINDERS', {});
      final filtered = await service.run('APPLEREMINDERS_LIST_REMINDERS', {'query': 'prima'});

      final titles = [
        for (final r in (result['data'] as Map)['reminders'] as List) (r as Map)['title'],
      ];
      expect(titles, ['Prima', 'Dopo', 'Senza data']);
      expect(((filtered['data'] as Map)['reminders'] as List), hasLength(1));
    });

    test('a request the model got wrong is explained, not thrown', () async {
      final noTitle = await service.run('APPLEREMINDERS_CREATE_REMINDER', {'title': ' '});
      final badDate = await service.run(
          'APPLEREMINDERS_CREATE_REMINDER', {'title': 'X', 'due': 'domani alle 9'});
      calendar.failure = const PhoneCalendarException('There is no Reminders list to add to');
      final noList = await service.run('APPLEREMINDERS_CREATE_REMINDER', {'title': 'X'});

      expect(noTitle, {'ok': false, 'error': 'title is required'});
      expect(badDate['error'], 'due is not a date and time: domani alle 9');
      expect(noList, {'ok': false, 'error': 'There is no Reminders list to add to'});
    });
  });

  test('an app turned off, or not allowed, says how to fix it', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final off = await service.run('APPLECALENDAR_LIST_EVENTS', {});
    await choices.set(PhoneApp.calendar, true);
    calendar.accessOf[PhoneApp.calendar] = PhoneAccess.denied;
    final denied = await service.run('APPLECALENDAR_LIST_EVENTS', {});
    final unknown = await service.run('GMAIL_SEND_EMAIL', {});

    expect(off['error'], contains('Profile → On this iPhone'));
    expect(denied['error'], contains('iOS Settings'));
    expect(unknown, {'ok': false, 'error': 'Unknown tool: GMAIL_SEND_EMAIL'});
  });

  test('on Android the fixes name the phone and Android settings', () async {
    final off = await service.run('APPLECALENDAR_LIST_EVENTS', {});
    await choices.set(PhoneApp.calendar, true);
    calendar.accessOf[PhoneApp.calendar] = PhoneAccess.denied;
    final denied = await service.run('APPLECALENDAR_LIST_EVENTS', {});

    expect(off['error'], contains('Profile → On this phone'));
    expect(denied['error'], contains('Android settings'));
  });

  group('calendar', () {
    setUp(() => turnOn(PhoneApp.calendar));

    test('an event lasts an hour unless told; a day is all-day', () async {
      final timed = await service.run('APPLECALENDAR_CREATE_EVENT', {
        'title': 'Cena con Marco',
        'start': '2026-10-16T20:00',
        'location': 'Da Gino',
      });
      await service.run('APPLECALENDAR_CREATE_EVENT', {
        'title': 'Ferie',
        'start': '2026-10-20',
      });

      expect(calendar.eventList.first.end, DateTime(2026, 10, 16, 21));
      expect(calendar.eventList.first.allDay, isFalse);
      expect((timed['data'] as Map)['start'], '2026-10-16T20:00');
      expect((timed['data'] as Map)['location'], 'Da Gino');
      expect(calendar.eventList.last.allDay, isTrue);
      expect(calendar.eventList.last.start, DateTime(2026, 10, 20));
    });

    test('an end before the start is refused', () async {
      final result = await service.run('APPLECALENDAR_CREATE_EVENT', {
        'title': 'X',
        'start': '2026-10-16T20:00',
        'end': '2026-10-16T19:00',
      });

      expect(result, {'ok': false, 'error': 'end must be after start'});
      expect(calendar.eventList, isEmpty);
    });

    test('listing: a day as the end is the whole day, at most 31 days', () async {
      calendar.eventList = [
        PhoneEvent(
          id: 'e1',
          title: 'Riunione budget',
          start: DateTime(2026, 10, 16, 11),
          end: DateTime(2026, 10, 16, 12),
          calendar: 'Lavoro',
          attendees: const [(name: 'Ada', email: 'ada@x.it'), (name: '', email: 'bo@x.it')],
        ),
      ];

      final result = await service.run('APPLECALENDAR_LIST_EVENTS', {
        'start': '2026-10-16',
        'end': '2026-10-16',
      });
      final tooLong = await service.run('APPLECALENDAR_LIST_EVENTS', {
        'start': '2026-10-01',
        'end': '2026-12-01',
      });

      expect(calendar.lastRange, (DateTime(2026, 10, 16), DateTime(2026, 10, 17)));
      final [event] = (result['data'] as Map)['events'] as List;
      expect(event, {
        'id': 'e1',
        'title': 'Riunione budget',
        'start': '2026-10-16T11:00',
        'end': '2026-10-16T12:00',
        'all_day': false,
        'calendar': 'Lavoro',
        'attendees': ['Ada', 'bo@x.it'],
      });
      expect(tooLong, {'ok': false, 'error': 'at most 31 days at a time'});
    });

    test('the next 36 hours go with the notifications, in UTC', () async {
      calendar.eventList = [
        PhoneEvent(
          id: 'e1',
          title: 'Call',
          start: DateTime(2026, 10, 15, 11),
          end: DateTime(2026, 10, 15, 12),
          calendar: 'Lavoro',
          notes: 'Budget',
          attendees: const [(name: 'Ada', email: 'ada@x.it')],
        ),
      ];

      final events = await service.upcomingEvents();

      expect(calendar.lastRange, (now, now.add(const Duration(hours: 36))));
      final start = DateTime(2026, 10, 15, 11);
      expect(events, [
        {
          'id': 'e1@${start.millisecondsSinceEpoch}',
          'title': 'Call',
          'start': start.toUtc().toIso8601String(),
          'all_day': false,
          'notes': 'Budget',
          'attendees': [
            {'name': 'Ada', 'email': 'ada@x.it'},
          ],
        },
      ]);
    });
  });

  test('no calendar events go out when the calendar is off', () async {
    expect(await service.upcomingEvents(), isEmpty);
    expect(calendar.lastRange, isNull);
  });

  test('a command is run and its result posted, even a failed one', () async {
    await service.handle(const PhoneActionCommand(
      id: 'c1',
      tool: 'APPLEREMINDERS_CREATE_REMINDER',
      arguments: {'title': 'Latte'},
    ));
    server.resultError = Exception('offline');
    await service.handle(const PhoneActionCommand(
      id: 'c2',
      tool: 'APPLEREMINDERS_CREATE_REMINDER',
      arguments: {'title': 'Pane'},
    ));

    expect(server.results.keys, ['c1']);
    expect(server.results['c1']!['ok'], isFalse); // Reminders is off
  });
}

typedef _Created = ({
  String title,
  String? notes,
  DateTime? due,
  bool dueHasTime,
  String? list,
});

final class _FakeCalendar implements PhoneCalendar {
  final accessOf = <PhoneApp, PhoneAccess>{};
  final requests = <PhoneApp>[];
  final created = <_Created>[];
  bool grant = false;
  PhoneCalendarException? failure;
  List<PhoneReminder> reminders = [];
  List<PhoneEvent> eventList = [];
  (DateTime, DateTime)? lastRange;

  @override
  Future<PhoneAccess> access(PhoneApp app) async => accessOf[app] ?? PhoneAccess.notAsked;

  @override
  Future<bool> requestAccess(PhoneApp app) async {
    requests.add(app);
    // As iOS: the answer is the access from then on
    accessOf[app] = grant ? PhoneAccess.granted : PhoneAccess.denied;
    return grant;
  }

  @override
  Future<PhoneReminder> createReminder({
    required String title,
    String? notes,
    DateTime? due,
    bool dueHasTime = true,
    String? list,
  }) async {
    if (failure != null) throw failure!;
    created.add((title: title, notes: notes, due: due, dueHasTime: dueHasTime, list: list));
    return PhoneReminder(
      id: 'r${created.length}',
      title: title,
      list: list ?? 'Promemoria',
      notes: notes,
      due: due,
      dueHasTime: dueHasTime,
    );
  }

  @override
  Future<List<PhoneReminder>> openReminders({DateTime? dueBefore}) async => reminders;

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
    final event = PhoneEvent(
      id: 'e${eventList.length + 1}',
      title: title,
      start: start,
      end: end,
      calendar: calendar ?? 'Calendario',
      allDay: allDay,
      location: location,
      notes: notes,
    );
    eventList = [...eventList, event];
    return event;
  }

  @override
  Future<List<PhoneEvent>> events({required DateTime start, required DateTime end}) async {
    lastRange = (start, end);
    return eventList;
  }
}

final class _FakeServer implements DeviceCommandsApi, PhoneAppsApi {
  final reports = <({bool reminders, bool calendar})>[];
  final results = <String, Map<String, Object?>>{};
  Object? resultError;

  @override
  Future<void> reportPhoneApps({required bool reminders, required bool calendar}) async {
    reports.add((reminders: reminders, calendar: calendar));
  }

  @override
  Future<void> sendCommandResult(String commandId, Map<String, Object?> result) async {
    if (resultError != null) throw resultError!;
    results[commandId] = result;
  }

  @override
  Future<List<DeviceCommand>> getDeviceCommands({Duration wait = Duration.zero}) async => [];
}
