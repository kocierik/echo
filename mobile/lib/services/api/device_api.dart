import '../../models/device_command.dart';
import 'api_client.dart';

/// What the server asks of this phone and its wearable, and the answers.
abstract interface class DeviceCommandsApi {
  /// Waits up to [wait] for a command (long poll).
  Future<List<DeviceCommand>> getDeviceCommands({Duration wait});

  /// What a [PhoneActionCommand] did: `{"ok": true, "data": …}` or
  /// `{"ok": false, "error": …}`.
  Future<void> sendCommandResult(String commandId, Map<String, Object?> result);
}

/// Which of the iPhone's apps Echo may use.
abstract interface class PhoneAppsApi {
  Future<void> reportPhoneApps({required bool reminders, required bool calendar});
}

mixin DeviceEndpoints on ApiClient implements DeviceCommandsApi, PhoneAppsApi {
  @override
  Future<List<DeviceCommand>> getDeviceCommands({
    Duration wait = const Duration(seconds: 20),
  }) async {
    final target = await url('/api/device/commands?wait=${wait.inSeconds}');
    final headers = await credentials.headers;
    final response = await send(
      () => httpClient.get(target, headers: headers),
      sentKey: headers['X-API-Key'],
      expect: const {200},
      shape: JsonShape.map,
      // The server holds the request open for up to `wait`
      timeout: wait + requestTimeout,
    );
    return parse(response.data, (data) {
      final commands = (data as Map<String, dynamic>)['commands'];
      if (commands is! List<dynamic>) throw const FormatException('commands');
      return commands
          .map(DeviceCommand.tryParse)
          .whereType<DeviceCommand>()
          .toList();
    });
  }

  @override
  Future<void> sendCommandResult(
    String commandId,
    Map<String, Object?> result,
  ) async {
    await post(
      '/api/device/commands/${Uri.encodeComponent(commandId)}/result',
      body: result,
      expect: const {204},
      decode: false,
    );
  }

  @override
  Future<void> reportPhoneApps({
    required bool reminders,
    required bool calendar,
  }) async {
    await put(
      '/api/device/phone-apps',
      body: {'reminders': reminders, 'calendar': calendar},
      decode: false,
    );
  }
}
