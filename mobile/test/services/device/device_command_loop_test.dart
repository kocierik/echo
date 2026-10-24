import 'dart:async';

import 'package:echo_app/models/device_command.dart';
import 'package:echo_app/services/api/device_api.dart';
import 'package:echo_app/services/device/device_command_loop.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('commands are read from the server JSON, unknown kinds skipped', () {
    final photo = DeviceCommand.tryParse({'type': 'take_photo', 'photo_id': 'p1'});
    expect(photo, isA<TakePhotoCommand>().having((c) => c.photoId, 'photoId', 'p1'));

    final action = DeviceCommand.tryParse({
      'type': 'phone_action',
      'id': 'c1',
      'tool': 'APPLEREMINDERS_CREATE_REMINDER',
      'arguments': {'title': 'Latte'},
    });
    expect(action, isA<PhoneActionCommand>());
    action as PhoneActionCommand;
    expect((action.id, action.tool, action.arguments['title']),
        ('c1', 'APPLEREMINDERS_CREATE_REMINDER', 'Latte'));

    expect(DeviceCommand.tryParse({'type': 'voice_update'}), isA<VoiceUpdateCommand>());
    expect(DeviceCommand.tryParse({'type': 'phone_action', 'tool': 'X'}), isNull);
    expect(DeviceCommand.tryParse({'type': 'launch_rocket'}), isNull);
    expect(DeviceCommand.tryParse('take_photo'), isNull);
  });

  test('each command goes to its handler, and polling goes on after errors', () async {
    final api = _FakeCommandsApi([
      const TakePhotoCommand('p1'),
      const PhoneActionCommand(id: 'c1', tool: 'APPLECALENDAR_LIST_EVENTS', arguments: {}),
    ])..errors = 2;
    final photos = <String>[];
    final actions = <String>[];
    final delays = <Duration>[];
    final loop = DeviceCommandLoop(
      api: api,
      onTakePhoto: (command) async => photos.add(command.photoId),
      onPhoneAction: (command) async => actions.add(command.id),
      sleep: (delay) async => delays.add(delay),
    )..start();

    await api.drained.future;
    loop.stop();

    expect(photos, ['p1']);
    expect(actions, ['c1']);
    expect(delays, [const Duration(seconds: 2), const Duration(seconds: 5)]);
  });

  test('a voice update runs the check for new answers', () async {
    final api = _FakeCommandsApi([const VoiceUpdateCommand()]);
    var checks = 0;
    final loop = DeviceCommandLoop(
      api: api,
      onTakePhoto: (_) async {},
      onPhoneAction: (_) async {},
      onVoiceUpdate: () async => checks++,
      sleep: (_) async {},
    )..start();

    await api.drained.future;
    loop.stop();

    expect(checks, 1);
  });

  test('a place asked for a saved thing goes to its handler', () async {
    final parsed = DeviceCommand.tryParse({'type': 'get_location', 'id': 'c9', 'item_id': 'car'});
    expect(
      parsed,
      isA<GetLocationCommand>()
          .having((c) => c.id, 'id', 'c9')
          .having((c) => c.itemId, 'itemId', 'car'),
    );
    expect(DeviceCommand.tryParse({'type': 'get_location'}), isNull);

    final api = _FakeCommandsApi([parsed!]);
    final asked = <String?>[];
    final loop = DeviceCommandLoop(
      api: api,
      onTakePhoto: (_) async {},
      onPhoneAction: (_) async {},
      onGetLocation: (command) async => asked.add(command.itemId),
      sleep: (_) async {},
    )..start();

    await api.drained.future;
    loop.stop();

    expect(asked, ['car']);
  });

  test('who is in front of you goes to its handler', () async {
    final parsed = DeviceCommand.tryParse({
      'type': 'person_brief',
      'person_id': 'p1',
      'title': 'Talking with Marco',
      'body': 'You promised: the quote',
    });
    expect(
      parsed,
      isA<PersonBriefCommand>()
          .having((c) => c.personId, 'personId', 'p1')
          .having((c) => c.title, 'title', 'Talking with Marco')
          .having((c) => c.body, 'body', 'You promised: the quote'),
    );
    expect(
      DeviceCommand.tryParse({'type': 'person_brief', 'person_id': 'p1', 'title': 'T'}),
      isNull,
    );

    final api = _FakeCommandsApi([parsed!]);
    final briefed = <String>[];
    final loop = DeviceCommandLoop(
      api: api,
      onTakePhoto: (_) async {},
      onPhoneAction: (_) async {},
      onPersonBrief: (command) async => briefed.add(command.personId),
      sleep: (_) async {},
    )..start();

    await api.drained.future;
    loop.stop();

    expect(briefed, ['p1']);
  });

  test('a slow phone action does not hold up the next command', () async {
    final slow = Completer<void>();
    final api = _FakeCommandsApi([
      const PhoneActionCommand(id: 'c1', tool: 'APPLECALENDAR_LIST_EVENTS', arguments: {}),
      const TakePhotoCommand('p1'),
    ]);
    final photos = <String>[];
    final loop = DeviceCommandLoop(
      api: api,
      onTakePhoto: (command) async => photos.add(command.photoId),
      onPhoneAction: (_) => slow.future,
      sleep: (_) async {},
    )..start();

    await api.drained.future;
    loop.stop();
    slow.complete();

    expect(photos, ['p1']);
  });
}

/// Hands out its commands one per poll, then nothing (completing [drained]).
final class _FakeCommandsApi implements DeviceCommandsApi {
  _FakeCommandsApi(List<DeviceCommand> commands) : _commands = [...commands];

  final List<DeviceCommand> _commands;
  final drained = Completer<void>();
  int errors = 0;

  @override
  Future<List<DeviceCommand>> getDeviceCommands({Duration wait = Duration.zero}) async {
    // Like the long poll: the loop never spins freely
    await Future<void>.delayed(Duration.zero);
    if (errors > 0) {
      errors--;
      throw Exception('offline');
    }
    if (_commands.isEmpty) {
      if (!drained.isCompleted) drained.complete();
      return const [];
    }
    return [_commands.removeAt(0)];
  }

  @override
  Future<void> sendCommandResult(String commandId, Map<String, Object?> result) async {}
}
