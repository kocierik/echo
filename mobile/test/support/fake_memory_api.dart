import 'dart:async';

import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/memory_graph.dart';
import 'package:echo_app/models/person.dart';
import 'package:echo_app/models/place.dart';
import 'package:echo_app/models/segment.dart';
import 'package:echo_app/models/task_item.dart';
import 'package:echo_app/models/today_insights.dart';
import 'package:echo_app/models/voice.dart';
import 'package:echo_app/services/api/api_exception.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/services/app/spoken_language.dart';

/// An in-memory [MemoryApi] (and [TranscriptMemoryApi]) recording every call.
class FakeMemoryApi implements MemoryApi, TranscriptMemoryApi {
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
  Map<String, List<ConversationCard>> topicConversations = {};
  MemoryGraph memoryGraph = const MemoryGraph(nodes: [], edges: []);
  Map<String, ConversationDetail> details;
  List<TaskItem> openTasks;
  List<TaskItem> doneTasks;
  MemorySearchResults searchResults =
      const MemorySearchResults(conversations: [], entities: []);
  List<PersonSummary> people = [];
  Map<String, PersonDetail> personDetails = {};
  Object? peopleError;

  /// Set to make the next calls of that kind fail.
  Object? listError;
  Object? detailError;
  Object? searchError;
  Object? taskError;
  Object? graphError;

  /// Completes a call only when the test says so.
  Completer<void>? gate;

  final List<String> calls = [];

  Future<void> _wait() async {
    final pending = gate;
    if (pending != null) await pending.future;
  }

  @override
  Future<List<ConversationCard>> listConversations({
    int limit = 30,
    int offset = 0,
    String? topic,
  }) async {
    calls.add('list $limit $offset${topic == null ? '' : ' topic=$topic'}');
    await _wait();
    if (listError case final error?) throw error;
    final source = topic == null
        ? conversations
        : topicConversations[topic] ?? const <ConversationCard>[];
    return source.skip(offset).take(limit).toList();
  }

  @override
  Future<MemoryGraph> getMemoryGraph({int days = 90}) async {
    calls.add('graph $days');
    await _wait();
    if (graphError case final error?) throw error;
    return memoryGraph;
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
  Future<List<TaskItem>> listTasks(
      {required bool done, int limit = 200}) async {
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
  Future<void> addPerson(String name) async {
    calls.add('add person $name');
    await _wait();
    if (peopleError case final error?) throw error;
  }

  @override
  Future<List<PersonSummary>> listPeople() async {
    calls.add('people');
    await _wait();
    if (peopleError case final error?) throw error;
    return List.of(people);
  }

  @override
  Future<PersonDetail> getPerson(String id) async {
    calls.add('person $id');
    await _wait();
    if (peopleError case final error?) throw error;
    final detail = personDetails[id];
    if (detail == null) {
      throw const ApiException(
        statusCode: 404,
        code: 'not_found',
        message: 'Person not found',
        retryable: false,
      );
    }
    return detail;
  }

  @override
  Future<void> deletePersonFact(String personId, String factId) async {
    calls.add('delete person fact $personId $factId');
    await _wait();
    if (taskError case final error?) throw error;
    final detail = personDetails[personId];
    if (detail == null) return;
    personDetails[personId] = PersonDetail(
      person: detail.person,
      conversations: detail.conversations,
      tasks: detail.tasks,
      events: detail.events,
      facts: detail.facts.where((fact) => fact.id != factId).toList(),
      earlierFacts: detail.earlierFacts.where((fact) => fact.id != factId).toList(),
    );
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

/// [FakeMemoryApi] plus what Today reads: the digest and pending actions.
class FakeTodayApi extends FakeMemoryApi
    implements
        TodayApi,
        WeeklySummaryApi,
        VoiceWorkingApi,
        VoiceApi,
        ComingUpApi,
        AccountApi,
        DigestApi {
  FakeTodayApi({
    super.conversations,
    super.openTasks,
    this.digest,
    this.week,
    List<PendingAction>? pending,
  }) : pending = pending ?? [];

  DailySummary? digest;

  /// Past days' digests, by day.
  Map<DateTime, DailySummary> digests = {};

  @override
  Future<DailySummary?> getDigest(DateTime day) async {
    calls.add('digest ${day.toIso8601String().substring(0, 10)}');
    return digests[day];
  }

  @override
  Future<AccountInfo> me() async => const AccountInfo(email: 'erik@x.io', language: 'en');

  @override
  Future<AccountInfo> setLanguage(String language) => throw UnimplementedError();

  @override
  Future<AccountInfo> setOtherLanguages(List<String> languages) =>
      throw UnimplementedError();

  /// The event in the next hour the server finds among the phone's ones.
  ComingUp? upcoming;
  final comingUpEvents = <List<Map<String, Object?>>>[];

  @override
  Future<ComingUp?> comingUp(List<Map<String, Object?>> phoneEvents) async {
    comingUpEvents.add(phoneEvents);
    return upcoming;
  }

  /// The weekly summary (not recorded in [calls]: optional for Today).
  WeeklySummary? week;

  /// Requests Echo is answering (not recorded in [calls]).
  List<WorkingItem> working = [];

  @override
  Future<List<WorkingItem>> getVoiceWorking() async => List.of(working);

  /// Voice recognition is off unless a test turns it on (no tip to record the voice).
  VoiceProfiles voices =
      const VoiceProfiles(fingerprintsEnabled: false, items: []);

  @override
  Future<VoiceProfiles> getVoiceProfiles() async => voices;

  @override
  Future<VoiceEnrollment> enrollOwnVoice(
          DateTime startedAt, DateTime endedAt) =>
      throw UnimplementedError();

  @override
  Future<void> deleteVoiceProfile(String id) => throw UnimplementedError();

  @override
  Future<int> nameVoice(String segmentId,
          {bool isSelf = false, String? personId, String? name, int? turn}) =>
      throw UnimplementedError();

  @override
  Future<void> rejectVoice(String segmentId) => throw UnimplementedError();

  @override
  Future<WeeklySummary?> getLatestWeeklySummary() async => week;

  Object? digestError;
  List<PendingAction> pending;
  ConfirmResult confirmResult =
      const ConfirmResult(status: 'executed', message: 'Done.');
  Object? confirmError;

  @override
  Future<DailySummary?> getLatestDigest() async {
    calls.add('digest');
    if (digestError case final error?) throw error;
    return digest;
  }

  @override
  Future<List<PendingAction>> listPendingActions() async {
    calls.add('pending');
    return List.of(pending);
  }

  @override
  Future<ConfirmResult> confirmPendingAction(String id) async {
    calls.add('confirm $id');
    if (confirmError case final error?) throw error;
    return confirmResult;
  }

  @override
  Future<void> cancelPendingAction(String id) async {
    calls.add('cancel $id');
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
  String? photoId,
  int segmentCount = 3,
  ConversationPlace? place,
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
    photoId: photoId,
    segmentCount: segmentCount,
    place: place,
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

/// A promise the user made, to [to] when known.
TaskItem promise(String id, String name, {String? to, DateTime? due, DateTime? createdAt}) {
  return TaskItem(
    id: id,
    name: name,
    dueDate: due,
    metadata: {
      'done': false,
      'promise': true,
      if (to != null) 'promise_to': to,
      if (due != null) 'due_date': due.toIso8601String().substring(0, 10),
    },
    createdAt: createdAt,
  );
}

ApiException serverError(String message) => ApiException(
      statusCode: 500,
      code: 'server',
      message: message,
      retryable: true,
    );
