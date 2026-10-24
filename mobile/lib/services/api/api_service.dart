import 'actions_api.dart';
import 'api_client.dart';
import 'auth_api.dart';
import 'chat_api.dart';
import 'device_api.dart';
import 'memory_api.dart';
import 'notifications_api.dart';
import 'photo_api.dart';
import 'places_api.dart';
import 'routines_api.dart';
import 'saved_api.dart';
import 'voice_api.dart';
import 'wearable_api.dart';

export 'actions_api.dart';
export 'api_client.dart' show ApiClient, JsonShape;
export 'auth_api.dart';
export 'api_credentials.dart';
export 'chat_api.dart';
export 'device_api.dart';
export 'memory_api.dart';
export 'notifications_api.dart';
export 'photo_api.dart';
export 'places_api.dart';
export 'routines_api.dart';
export 'saved_api.dart';
export 'voice_api.dart';

/// The Echo server: every screen's interface, from the endpoint groups in this folder
/// (one file each), over the shared transport of [ApiClient].
class ApiService extends ApiClient
    with
        ChatEndpoints,
        MemoryEndpoints,
        ActionEndpoints,
        PhotoEndpoints,
        DeviceEndpoints,
        VoiceEndpoints,
        NotificationEndpoints,
        RoutineEndpoints,
        SavedEndpoints,
        PlacesEndpoints,
        WearableEndpoints,
        AuthEndpoints
    implements TodayApi {
  ApiService({
    super.client,
    super.credentialStore,
    super.requestTimeout,
    super.uploadTimeout,
    super.queryTimeout,
    super.cache,
    super.cacheOnly,
  });

  /// The same reads, from the phone's copy only (throws when there is none).
  ApiService cacheView() => ApiService(
        client: httpClient,
        credentialStore: credentials,
        cache: cache,
        cacheOnly: true,
      );

  Future<bool> isConfigured() => credentials.configured;

  Future<void> configure(String serverUrl, String apiKey) =>
      credentials.configure(serverUrl, apiKey);

  Future<void> clearConfiguration() => credentials.clear();

  Future<String> getServerUrl() => credentials.serverUrl;

  /// Whether [apiKey] opens [serverUrl], before saving them.
  Future<bool> validateCredentials(String serverUrl, String apiKey) async {
    final normalizedServer = serverUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final response = await send(
      () => httpClient.get(
        Uri.parse('$normalizedServer/api/conversations?limit=1'),
        headers: {'X-API-Key': apiKey.trim()},
      ),
      expect: const {200, 401, 403},
      decode: false,
    );
    return response.statusCode == 200;
  }

  /// Whether the saved server and key work.
  Future<bool> testConnection() async {
    final target = await url('/api/conversations?limit=1');
    final headers = await credentials.headers;
    final response = await send(
      () => httpClient.get(target, headers: headers),
      expect: const {200, 401, 403},
      decode: false,
    );
    return response.statusCode == 200;
  }
}
