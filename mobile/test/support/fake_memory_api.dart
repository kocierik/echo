import 'dart:async';

import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/segment.dart';
import 'package:echo_app/models/task_item.dart';
import 'package:echo_app/services/api_exception.dart';
import 'package:echo_app/services/api_service.dart';

/// An in-memory [MemoryApi] (and [TranscriptMemoryApi]) recording every call.
final class FakeMemoryApi implements MemoryApi, TranscriptMemoryApi {
  FakeMemoryApi({
    List<ConversationCard>? conversations,
    Map<String, ConversationDetail>? details,
    List<TaskItem>? openTasks,
    List<TaskItem>? doneTasks,
  })  : conversations = conversations ?? [],
        details = details ?? {},
        openTasks = openTasks ?? [],
        doneTasks = doneTasks ?? [];

  List<ConversationCard> conversations;
  Map<String, ConversationDetail> details;
  List<TaskItem> openTasks;
  List<TaskItem> doneTasks;
  MemorySearchResults searchResults =
      const MemorySearchResults(conversations: [], entities: []);

  /// Set to make the next calls of that kind fail.
  Object? listError;
  Object? detailError;
  Object? searchError;
  Object? taskError;

  /// Completes a call only when the test says so.
  Completer<void>? gate;

  final List<String> calls = [];

  Future<void> _wait() async {
    final pending = gate;
    if (pending != null) await pending.future;
  }

  @override
  Future<List<ConversationCard>> listConversations({int limit = 30, int offset = 0}) async {
    calls.add('list $limit $offset');
    await _wait();
    if (listError case final error?) throw error;
    return conversations.skip(offset).take(limit).toList();
  }

  @override
  Future<ConversationDetail> getConversation(String id) async {
    calls.add('detail $id');
    await _wait();
    if (detailError case final error?) throw error;
    final detail = details[id];
    if (detail == null) {
      throw const ApiException(
        statusCode: 404,
        code: 'not_found',
        message: 'Conversation not found',
        retryable: false,
      );
    }
    return detail;
  }

  @override
  Future<MemorySearchResults> search(String query) async {
    calls.add('search $query');
    await _wait();
    if (searchError case final error?) throw error;
    return searchResults;
  }

  @override
  Future<List<TaskItem>> listTasks({required bool done, int limit = 200}) async {
    calls.add('tasks $done');
    await _wait();
    if (listError case final error?) throw error;
    return List.of(done ? doneTasks : openTasks);
  }

  @override
  Future<void> setTaskDone(TaskItem task, bool done) async {
    calls.add('done ${task.id} $done');
    await _wait();
    if (taskError case final error?) throw error;
  }

  @override
  Future<void> deleteEntity(String id) async {
    calls.add('delete entity $id');
    await _wait();
    if (taskError case final error?) throw error;
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    calls.add('delete conversation $conversationId');
    await _wait();
  }

  @override
  Future<TranscriptionCorrectionResult> correctTranscription(
    String segmentId,
    String text,
    String speaker,
  ) {
    throw UnimplementedError();
  }
}

ConversationCard card(
  String id, {
  required DateTime startedAt,
  String? title = 'Lunch with Ada',
  String? summary = 'Ada proposes Atlas.',
  String? emoji = '🍝',
  Duration duration = const Duration(minutes: 12),
  bool isOpen = false,
  String analysisStatus = 'completed',
  List<String> people = const ['Ada'],
  int taskCount = 1,
}) {
  return ConversationCard(
    id: id,
    title: title,
    summary: summary,
    emoji: emoji,
    startedAt: startedAt,
    endedAt: startedAt.add(duration),
    duration: duration,
    isOpen: isOpen,
    analysisStatus: analysisStatus,
    people: people,
    taskCount: taskCount,
  );
}

TaskItem task(
  String id,
  String name, {
  DateTime? due,
  bool done = false,
  String? source,
  String? conversationId = 'c1',
  DateTime? createdAt,
}) {
  return TaskItem(
    id: id,
    name: name,
    dueDate: due,
    metadata: {'done': done},
    sourceText: source,
    conversationId: conversationId,
    createdAt: createdAt,
  );
}

ApiException serverError(String message) => ApiException(
      statusCode: 500,
      code: 'server',
      message: message,
      retryable: true,
    );
