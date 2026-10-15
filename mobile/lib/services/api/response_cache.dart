import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// A server response kept on the phone, and when it was received.
@immutable
final class CachedBody {
  const CachedBody(this.body, this.savedAt);

  final String body;
  final DateTime savedAt;
}

/// The last answer to each read, so the app still shows something offline. It holds
/// the user's memory: it lives in the app's private folder and goes on logout.
abstract interface class ResponseCache {
  Future<CachedBody?> read(String key);
  Future<void> write(String key, String body);
  Future<void> clear();
}

/// One file per request, in the app support folder (not backed up to iCloud, not
/// readable by other apps).
final class FileResponseCache implements ResponseCache {
  FileResponseCache({Future<Directory> Function()? directory})
      : _directory = directory ?? _defaultDirectory;

  static final FileResponseCache shared = FileResponseCache();

  final Future<Directory> Function() _directory;

  static Future<Directory> _defaultDirectory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/api_cache');

  Future<File> _file(String key) async {
    final name = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    return File('${(await _directory()).path}/$name.json');
  }

  @override
  Future<CachedBody?> read(String key) async {
    try {
      final file = await _file(key);
      if (!await file.exists()) return null;
      final stored = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return CachedBody(
        stored['body'] as String,
        DateTime.parse(stored['saved_at'] as String),
      );
    } catch (_) {
      return null; // a damaged entry is just a miss
    }
  }

  @override
  Future<void> write(String key, String body) async {
    try {
      final file = await _file(key);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'saved_at': DateTime.now().toUtc().toIso8601String(),
        'body': body,
      }));
    } catch (error) {
      debugPrint('[Cache] could not save $key: $error');
    }
  }

  @override
  Future<void> clear() async {
    final directory = await _directory();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// For tests and previews.
final class MemoryResponseCache implements ResponseCache {
  final Map<String, CachedBody> entries = {};
  DateTime Function() clock = DateTime.now;

  @override
  Future<CachedBody?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, String body) async =>
      entries[key] = CachedBody(body, clock());

  @override
  Future<void> clear() async => entries.clear();
}

/// Whether what the app shows came from the phone because the server was unreachable:
/// the time it was received, or null when it is fresh. One for the whole app.
final ValueNotifier<DateTime?> offlineDataSince = ValueNotifier(null);
