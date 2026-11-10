import 'package:flutter/foundation.dart';

import '../../models/action_models.dart';
import '../../models/memory.dart';
import '../../models/person.dart';
import '../../models/segment.dart';
import '../../models/task_item.dart';
import '../../models/today_insights.dart';
import 'api_client.dart';
import 'api_exception.dart';

/// What the Memories and Tasks screens read and change.
abstract interface class MemoryApi {
  Future<List<ConversationCard>> listConversations({int limit = 30, int offset = 0});
  Future<ConversationDetail> getConversation(String id);
  Future<MemorySearchResults> search(String query);
  Future<List<TaskItem>> listTasks({required bool done, int limit = 200});
  Future<void> setTaskDone(TaskItem task, bool done);
  Future<void> deleteEntity(String id);
  Future<void> deleteConversation(String conversationId);
  Future<List<PersonSummary>> listPeople();
  Future<PersonDetail> getPerson(String id);
  Future<void> deletePersonFact(String personId, String factId);
}

/// Actions waiting for the user's Confirm (actions_api.dart).
abstract interface class PendingActionsApi {
  Future<List<PendingAction>> listPendingActions();
  Future<ConfirmResult> confirmPendingAction(String id);
  Future<void> cancelPendingAction(String id);
}

/// Everything Today reads and does: the memory, plus the digest and the actions
/// waiting for a Confirm.
abstract interface class TodayApi implements MemoryApi, PendingActionsApi {
  Future<DailySummary?> getLatestDigest();
}

/// A past day's digest (optional: a day opened from Today shows it at the top).
abstract interface class DigestApi {
  /// The digest of [day], or null when that day has none.
  Future<DailySummary?> getDigest(DateTime day);
}

/// Weekly summaries (optional for a Today api: no section without it).
abstract interface class WeeklySummaryApi {
  /// The latest weekly summary of the last two weeks, or null.
  Future<WeeklySummary?> getLatestWeeklySummary();
}

abstract interface class TranscriptMemoryApi {
  Future<TranscriptionCorrectionResult> correctTranscription(
    String segmentId,
    String text,
    String speaker,
  );
  Future<void> deleteConversation(String conversationId);
}

/// A conversation's lines heard in another language, in the user's [language], by
/// segment id (`POST /api/conversations/{id}/translate`).
@immutable
final class TranscriptTranslation {
  const TranscriptTranslation({required this.language, required this.lines});

  factory TranscriptTranslation.fromJson(Map<String, dynamic> json) => TranscriptTranslation(
        language: json['language'] as String,
        lines: {
          for (final MapEntry(:key, :value)
              in (json['lines'] as Map<String, dynamic>? ?? const {}).entries)
            if (value is String) key: value,
        },
      );

  final String language;
  final Map<String, String> lines;
}

/// Translating a transcript into the user's language.
abstract interface class TranslateApi {
  Future<TranscriptTranslation> translateConversation(String id);
}

/// Conversations, tasks, people, summaries and the user's whole data.
mixin MemoryEndpoints on ApiClient
    implements MemoryApi, TranscriptMemoryApi, WeeklySummaryApi, DigestApi, TranslateApi {
  @override
  Future<TranscriptTranslation> translateConversation(String id) async {
    // One model call for the whole transcript the first time
    final response = await post(
      '/api/conversations/${Uri.encodeComponent(id)}/translate',
      timeout: const Duration(seconds: 90),
    );
    return parse(
      response.data,
      (data) => TranscriptTranslation.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<DailySummary?> getDigest(DateTime day) async {
    final date = '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    try {
      final response = await getCached('/api/digest/$date');
      return parse(
        response.data,
        (data) => DailySummary.fromJson(data as Map<String, dynamic>),
      );
    } on ApiException catch (error) {
      if (error.code == 'not_found') return null; // a day without one
      rethrow;
    }
  }

  @override
  Future<List<ConversationCard>> listConversations({
    int limit = 30,
    int offset = 0,
  }) async {
    final response =
        await getCached('/api/conversations?limit=$limit&offset=$offset');
    return parse(response.data, (data) {
      final items =
          (data as Map<String, dynamic>)['conversations'] as List<dynamic>;
      return items
          .map((item) => ConversationCard.fromJson(item as Map<String, dynamic>))
          .toList();
    });
  }

  @override
  Future<ConversationDetail> getConversation(String id) async {
    final response =
        await getCached('/api/conversations/${Uri.encodeComponent(id)}');
    return parse(
      response.data,
      (data) => ConversationDetail.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<void> deleteConversation(String id) =>
      delete('/api/conversations/$id');

  @override
  Future<TranscriptionCorrectionResult> correctTranscription(
    String segmentId,
    String text,
    String speaker,
  ) async {
    final response = await patch(
      '/api/segments/$segmentId/transcription',
      body: {'text': text.trim(), 'speaker': speaker},
      expect: const {200, 202},
    );
    return parse(
      response.data,
      (data) => TranscriptionCorrectionResult.fromJson(
        data as Map<String, dynamic>,
      ),
    );
  }

  @override
  Future<MemorySearchResults> search(String query) async {
    final q = Uri.encodeQueryComponent(query.trim());
    final response = await getCached('/api/search?q=$q');
    return parse(
      response.data,
      (data) => MemorySearchResults.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<List<TaskItem>> listTasks({required bool done, int limit = 200}) async {
    final response =
        await getCached('/api/entities/tasks?done=$done&limit=$limit');
    return parse(response.data, (data) {
      final items = (data as Map<String, dynamic>)['entities'] as List<dynamic>;
      return items
          .map((item) => TaskItem.fromJson(item as Map<String, dynamic>))
          .where((task) => task.name.isNotEmpty)
          .toList();
    });
  }

  @override
  Future<void> setTaskDone(TaskItem task, bool done) {
    return updateEntity(task.id, metadata: task.metadataWithDone(done));
  }

  Future<void> updateEntity(
    String id, {
    String? name,
    String? content,
    Map<String, dynamic>? metadata,
  }) async {
    await patch('/api/entities/$id', body: {
      if (name != null) 'name': name,
      if (content != null) 'content': content,
      if (metadata != null) 'metadata_': metadata,
    });
  }

  @override
  Future<void> deleteEntity(String id) =>
      delete('/api/entities/${Uri.encodeComponent(id)}');

  @override
  Future<List<PersonSummary>> listPeople() async {
    final response = await getCached('/api/people', shape: JsonShape.list);
    return parse(response.data, (data) {
      return (data as List<dynamic>)
          .map((item) => PersonSummary.fromJson(item as Map<String, dynamic>))
          .where((person) => person.name.isNotEmpty)
          .toList();
    });
  }

  @override
  Future<PersonDetail> getPerson(String id) async {
    final response = await getCached('/api/people/${Uri.encodeComponent(id)}');
    return parse(
      response.data,
      (data) => PersonDetail.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<void> deletePersonFact(String personId, String factId) => delete(
        '/api/people/${Uri.encodeComponent(personId)}/facts/${Uri.encodeComponent(factId)}',
      );

  /// The most recent daily digest of the last two days, or null if none exists.
  Future<DailySummary?> getLatestDigest() async {
    final response = await getCached('/api/digest?days=2');
    return parse(response.data, (data) {
      final items = (data as Map<String, dynamic>)['items'] as List<dynamic>;
      final summaries = items
          .map((item) => DailySummary.fromJson(item as Map<String, dynamic>))
          .where((digest) => digest.summary.isNotEmpty)
          .toList();
      return summaries.isEmpty ? null : summaries.first;
    });
  }

  @override
  Future<WeeklySummary?> getLatestWeeklySummary() async {
    final response = await getCached('/api/digest/weekly?weeks=2');
    return parse(response.data, (data) {
      final items = (data as Map<String, dynamic>)['items'] as List<dynamic>;
      final weeks = items
          .map((item) => WeeklySummary.fromJson(item as Map<String, dynamic>))
          .where((week) => week.summary.isNotEmpty)
          .toList();
      return weeks.isEmpty ? null : weeks.first;
    });
  }

  /// Everything the server keeps about the user, as the JSON file to save.
  Future<List<int>> exportData() => getBytes('/api/export');
}
