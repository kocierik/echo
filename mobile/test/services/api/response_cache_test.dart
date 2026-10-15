import 'dart:io';

import 'package:echo_app/services/api/response_cache.dart';
import 'package:echo_app/services/app/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory folder;
  late FileResponseCache cache;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('echo_cache_test');
    cache = FileResponseCache(
        directory: () async => Directory('${folder.path}/api_cache'));
  });

  tearDown(() async {
    if (await folder.exists()) await folder.delete(recursive: true);
  });

  test('a copy is written, read back and cleared', () async {
    expect(await cache.read('https://echo.test/api/people'), isNull);

    await cache.write('https://echo.test/api/people', '[{"id":"p1"}]');
    final copy = await cache.read('https://echo.test/api/people');

    expect(copy!.body, '[{"id":"p1"}]');
    expect(DateTime.now().difference(copy.savedAt).inMinutes, lessThan(1));
    await cache.clear();
    expect(await cache.read('https://echo.test/api/people'), isNull);
  });

  test('a damaged copy is a miss, not an error', () async {
    await cache.write('k', '{}');
    final file =
        (await Directory('${folder.path}/api_cache').list().first) as File;
    await file.writeAsString('not json');
    expect(await cache.read('k'), isNull);
  });

  test('logout clears the copy with the other local data', () async {
    SharedPreferences.setMockInitialValues({'notify_evening': true});
    final preferences = await SharedPreferences.getInstance();
    await cache.write('k', '{}');

    await SharedPreferencesSessionCacheClearer(preferences, responses: cache)
        .clear();

    expect(await cache.read('k'), isNull);
    expect(preferences.getBool('notify_evening'), isNull);
  });
}
