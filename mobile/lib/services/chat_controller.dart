import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import 'api_exception.dart';
import 'api_service.dart';
import 'request_id.dart';
import 'voice_input.dart';

typedef ChatClock = DateTime Function();

/// Server detail of a 409 while the same client_request_id is still running.
const stillWorkingDetail = 'Still working on it';
const stillWorkingMessage = 'Echo is still working on your last request.';

@immutable
final class ChatState {
  ChatState({
    required List<ChatMessage> messages,
    required this.sessionId,
    required this.title,
    required this.sending,
    required this.loadingSession,
    required this.error,
    required this.composerText,
    required this.listening,
    Set<String> busyActionIds = const {},
  })  : busyActionIds = Set<String>.unmodifiable(busyActionIds),
        messages = List<ChatMessage>.unmodifiable(messages);

  factory ChatState.initial() => ChatState(
        messages: const [],
        sessionId: null,
        title: null,
        sending: false,
        loadingSession: false,
        error: null,
        composerText: '',
        listening: false,
      );

  final List<ChatMessage> messages;
  final String? sessionId;
  final String? title;
  final bool sending;
  final bool loadingSession;
  final String? error;
  final String composerText;
  final bool listening;
  final Set<String> busyActionIds;

  bool get canRetry => messages.any(
        (message) => message.isUser && message.failed,
      );

  ChatState copyWith({
    List<ChatMessage>? messages,
    Object? sessionId = _unset,
    Object? title = _unset,
    bool? sending,
    bool? loadingSession,
    Object? error = _unset,
    String? composerText,
    bool? listening,
    Set<String>? busyActionIds,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      sessionId:
          identical(sessionId, _unset) ? this.sessionId : sessionId as String?,
      title: identical(title, _unset) ? this.title : title as String?,
      sending: sending ?? this.sending,
      loadingSession: loadingSession ?? this.loadingSession,
      error: identical(error, _unset) ? this.error : error as String?,
      composerText: composerText ?? this.composerText,
      listening: listening ?? this.listening,
      busyActionIds: busyActionIds ?? this.busyActionIds,
    );
  }
}

final class ChatController extends ChangeNotifier {
  ChatController({
    required ChatApi api,
    required VoiceInput voiceInput,
    ChatClock? clock,
    String Function()? requestIdFactory,
  })  : _api = api,
        _voiceInput = voiceInput,
        _clock = clock ?? DateTime.now,
        _newRequestId = requestIdFactory ?? newRequestId;

  final ChatApi _api;
  final VoiceInput _voiceInput;
  final ChatClock _clock;
  final String Function() _newRequestId;

  ChatApi get api => _api;

  ChatState _state = ChatState.initial();
  ChatState get state => _state;

  int _generation = 0;
  int _voiceGeneration = 0;
  bool _disposed = false;

  void setComposerText(String text) {
    if (_disposed || text == _state.composerText) return;
    _emit(_state.copyWith(composerText: text));
  }

  Future<void> send(String text) async {
    final question = text.trim();
    if (question.isEmpty || _state.sending || _state.loadingSession) return;

    final messages = [
      ..._state.messages,
      ChatMessage(
        text: question,
        isUser: true,
        timestamp: _clock(),
        clientRequestId: _newRequestId(),
      ),
    ];
    final userIndex = messages.length - 1;
    _emit(_state.copyWith(
      messages: messages,
      title: _state.title ?? question,
      sending: true,
      error: null,
      composerText: '',
    ));
    await _query(question, userIndex: userIndex);
  }

  Future<void> retryLastFailed() async {
    if (_state.sending || _state.loadingSession) return;
    final userIndex = _state.messages.lastIndexWhere(
      (message) => message.isUser && message.failed,
    );
    if (userIndex < 0) return;

    final messages = [..._state.messages];
    final question = messages[userIndex].text;
    // The message keeps its clientRequestId: the server returns the first
    // attempt's answer instead of running the request (and its actions) again.
    messages[userIndex] = messages[userIndex].copyWith(failed: false);
    _emit(_state.copyWith(
      messages: messages,
      sending: true,
      error: null,
    ));
    await _query(question, userIndex: userIndex);
  }

  Future<void> _query(String question, {required int userIndex}) async {
    final generation = _generation;
    try {
      final response = await _api.query(
        question,
        sessionId: _state.sessionId,
        clientRequestId: _state.messages[userIndex].clientRequestId,
      );
      if (!_isCurrent(generation)) return;
      final assistantIndex = _state.messages
              .where((message) => !message.isUser && message.index != null)
              .length +
          1;
      _emit(_state.copyWith(
        messages: [
          ..._state.messages,
          ChatMessage(
            text: response.answer,
            isUser: false,
            index: assistantIndex,
            timestamp: _clock(),
            sources: _mapSources(response.sources),
            pendingAction: response.pendingAction,
          ),
        ],
        sessionId: response.sessionId,
        sending: false,
        error: null,
      ));
    } catch (error) {
      if (!_isCurrent(generation)) return;
      final messages = [..._state.messages];
      if (userIndex < messages.length) {
        messages[userIndex] = messages[userIndex].copyWith(failed: true);
      }
      final stillWorking = error is ApiException &&
          error.code == 'conflict' &&
          error.message == stillWorkingDetail;
      _emit(_state.copyWith(
        messages: messages,
        sending: false,
        error: stillWorking
            ? stillWorkingMessage
            : _errorMessage(error, 'Could not send your question.'),
      ));
    }
  }

  void newChat() {
    _generation++;
    _voiceGeneration++;
    if (_state.listening) unawaited(_voiceInput.cancel());
    _emit(ChatState.initial());
  }

  Future<void> loadSession(String id) async {
    final generation = ++_generation;
    _voiceGeneration++;
    if (_state.listening) unawaited(_voiceInput.cancel());
    _emit(ChatState.initial().copyWith(
      sessionId: id,
      loadingSession: true,
    ));

    try {
      final detail = await _api.getSessionDetail(id);
      if (!_isCurrent(generation)) return;
      var assistantIndex = 0;
      final messages = detail.messages.map((message) {
        final isUser = message.role == 'user';
        if (!isUser) assistantIndex++;
        return ChatMessage(
          text: message.content,
          isUser: isUser,
          index: isUser ? null : assistantIndex,
          timestamp: message.timestamp,
          sources: _mapSources(message.citations ?? const []),
          pendingAction: message.pendingAction,
        );
      }).toList();
      _emit(_state.copyWith(
        messages: messages,
        sessionId: detail.id,
        title: detail.title,
        loadingSession: false,
        error: null,
      ));
    } catch (error) {
      if (!_isCurrent(generation)) return;
      final notFound = error is ApiException && error.code == 'not_found';
      _emit(_state.copyWith(
        sessionId: notFound ? null : id,
        loadingSession: false,
        error: _errorMessage(error, 'Could not load this chat.'),
      ));
    }
  }

  Future<void> deleteSession(String id) async {
    await _api.deleteSession(id);
    if (_disposed) return;
    if (_state.sessionId == id) newChat();
  }

  Future<void> sendFeedback(int messageIndex, String rating) async {
    final sessionId = _state.sessionId;
    if (sessionId == null) return;
    final listIndex = _state.messages.indexWhere(
      (message) => !message.isUser && message.index == messageIndex,
    );
    if (listIndex < 0) return;

    final generation = _generation;
    final previous = _state.messages[listIndex];
    final messages = [..._state.messages];
    messages[listIndex] = previous.copyWith(feedback: rating);
    _emit(_state.copyWith(messages: messages, error: null));

    try {
      await _api.sendFeedback(
        sessionId: sessionId,
        messageIndex: messageIndex,
        rating: rating,
        chunkIds: previous.sources
            .map((source) => source.chunkId)
            .whereType<String>()
            .toList(),
      );
    } catch (error) {
      if (!_isCurrent(generation)) return;
      final currentIndex = _state.messages.indexWhere(
        (message) => !message.isUser && message.index == messageIndex,
      );
      if (currentIndex < 0) return;
      final reverted = [..._state.messages];
      reverted[currentIndex] = previous;
      _emit(_state.copyWith(
        messages: reverted,
        error: _errorMessage(error, 'Could not save feedback.'),
      ));
    }
  }

  /// Confirms the pending action [id]; ignored while a request for it is in
  /// flight or once it is no longer pending.
  Future<void> confirmAction(String id) async {
    if (!_beginAction(id)) return;
    final generation = _generation;
    try {
      final result = await _api.confirmPendingAction(id);
      if (!_isCurrent(generation)) return;
      _finishAction(id, result.status, result.message);
    } on ApiException catch (error) {
      if (!_isCurrent(generation)) return;
      if (error.code == 'expired') {
        _finishAction(id, 'expired', 'This request expired. Ask again.');
      } else if (error.code == 'conflict') {
        _finishAction(id, 'resolved', 'This request was already handled.');
      } else {
        _failAction(id, error.message);
      }
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _failAction(id, _errorMessage(error, 'Could not confirm this action.'));
    }
  }

  Future<void> cancelAction(String id) async {
    if (!_beginAction(id)) return;
    final generation = _generation;
    try {
      await _api.cancelPendingAction(id);
      if (!_isCurrent(generation)) return;
      _finishAction(id, 'cancelled', 'Cancelled.');
    } on ApiException catch (error) {
      if (!_isCurrent(generation)) return;
      if (error.code == 'expired') {
        _finishAction(id, 'expired', 'This request expired. Ask again.');
      } else if (error.code == 'conflict') {
        _finishAction(id, 'resolved', 'This request was already handled.');
      } else {
        _failAction(id, error.message);
      }
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _failAction(id, _errorMessage(error, 'Could not cancel this action.'));
    }
  }

  int _actionIndex(String id) => _state.messages.indexWhere(
        (message) => message.pendingAction?.id == id,
      );

  bool _beginAction(String id) {
    if (_disposed || _state.busyActionIds.contains(id)) return false;
    final index = _actionIndex(id);
    if (index < 0) return false;
    final status = _state.messages[index].pendingAction!.status;
    if (status != null && status != 'pending') return false;
    _emit(_state.copyWith(
      busyActionIds: {..._state.busyActionIds, id},
      error: null,
    ));
    return true;
  }

  void _finishAction(String id, String status, String reply) {
    final messages = [..._state.messages];
    final index = _actionIndex(id);
    if (index >= 0) {
      final message = messages[index];
      messages[index] = message.copyWith(
        pendingAction: message.pendingAction!.copyWith(status: status),
      );
    }
    messages.add(ChatMessage(
      text: reply,
      isUser: false,
      timestamp: _clock(),
    ));
    _emit(_state.copyWith(
      messages: messages,
      busyActionIds: _state.busyActionIds.where((e) => e != id).toSet(),
    ));
  }

  void _failAction(String id, String error) {
    _emit(_state.copyWith(
      busyActionIds: _state.busyActionIds.where((e) => e != id).toSet(),
      error: error,
    ));
  }

  Future<void> startVoice() async {
    if (_state.listening) return;
    final generation = ++_voiceGeneration;
    _emit(_state.copyWith(error: null));
    try {
      if (!await _voiceInput.available()) {
        if (_isVoiceCurrent(generation)) {
          _emit(_state.copyWith(error: 'Voice input is unavailable.'));
        }
        return;
      }
      if (!await _voiceInput.request()) {
        if (_isVoiceCurrent(generation)) {
          _emit(_state.copyWith(error: 'Microphone permission was denied.'));
        }
        return;
      }
      if (!_isVoiceCurrent(generation)) return;
      _emit(_state.copyWith(listening: true));
      await _voiceInput.start(
        onPartial: (text) => _onVoiceText(generation, text),
        onFinal: (text) => _onVoiceText(generation, text),
      );
    } catch (error) {
      if (!_isVoiceCurrent(generation)) return;
      _emit(_state.copyWith(
        listening: false,
        error: _errorMessage(error, 'Could not start voice input.'),
      ));
    }
  }

  Future<void> stopVoice() async {
    if (!_state.listening) return;
    final generation = _voiceGeneration;
    try {
      await _voiceInput.stop();
    } catch (error) {
      if (_isVoiceCurrent(generation)) {
        _emit(_state.copyWith(
          error: _errorMessage(error, 'Could not stop voice input.'),
        ));
      }
    } finally {
      if (_isVoiceCurrent(generation)) {
        _emit(_state.copyWith(listening: false));
      }
    }
  }

  void _onVoiceText(int generation, String text) {
    if (!_isVoiceCurrent(generation) || !_state.listening) return;
    _emit(_state.copyWith(composerText: text));
  }

  List<ChatSource> _mapSources(List<Map<String, dynamic>> sources) {
    return List<ChatSource>.generate(sources.length, (index) {
      final source = sources[index];
      final rawUrl = source['url'];
      final url = rawUrl is String && rawUrl.isNotEmpty
          ? Uri.tryParse(rawUrl)
          : null;
      return ChatSource(
        label: _sourceLabel(source, index),
        text: source['text'] is String ? source['text'] as String : '',
        chunkId:
            source['chunk_id'] is String ? source['chunk_id'] as String : null,
        url: url?.hasScheme == true ? url : null,
      );
    });
  }

  String _sourceLabel(Map<String, dynamic> source, int index) {
    final label = source['label'];
    if (label is String && label.trim().isNotEmpty) return label.trim();
    return 'Source ${index + 1}';
  }

  String _errorMessage(Object error, String fallback) {
    if (error is ApiException) return error.message;
    final message = error.toString().replaceFirst('Exception: ', '').trim();
    return message.isEmpty ? fallback : message;
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _generation;

  bool _isVoiceCurrent(int generation) =>
      !_disposed && generation == _voiceGeneration;

  void _emit(ChatState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _voiceGeneration++;
    unawaited(_voiceInput.cancel());
    super.dispose();
  }
}

const _unset = Object();