import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../services/api/api_service.dart';
import '../services/chat/chat_controller.dart';
import '../services/device/photo_service.dart';
import '../services/chat/voice_input.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_composer.dart';
import '../widgets/message_bubble.dart';
import '../widgets/typing_indicator.dart';
import '../utils/chat_suggestions.dart';
import 'chat_history_screen.dart';
import 'conversation_detail_screen.dart';

final class ChatScreen extends StatefulWidget {
  const ChatScreen({
    this.controller,
    this.api,
    this.voiceInput,
    this.openSessionRequest,
    this.askRequest,
    this.memoryApi,
    this.photoTaker,
    super.key,
  });

  final ChatController? controller;

  /// The wearable camera; no camera button without it.
  final PhotoTaker? photoTaker;
  final ChatApi? api;
  final VoiceInput? voiceInput;

  /// A session id to open (set e.g. by a notification tap); the screen loads
  /// it and sets the notifier back to null.
  final ValueNotifier<String?>? openSessionRequest;

  /// A question to send in a new chat, consumed (set to null) once sent.
  final ValueNotifier<String?>? askRequest;

  /// Opens the conversations sources come from (defaults to the chat's api).
  final MemoryApi? memoryApi;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

final class _ChatScreenState extends State<ChatScreen> {
  List<String> _suggestions = defaultChatSuggestions;

  late final ChatController _controller;
  late final ChatApi _api;
  late final bool _ownsController;
  late final bool _ownsApi;
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  int _messageCount = 0;

  @override
  void initState() {
    super.initState();
    final injectedController = widget.controller;
    if (injectedController != null) {
      _controller = injectedController;
      _api = injectedController.api;
      _ownsController = false;
      _ownsApi = false;
    } else {
      _api = widget.api ?? ApiService();
      _ownsApi = widget.api == null;
      _controller = ChatController(
        api: _api,
        voiceInput: widget.voiceInput ?? SpeechToTextVoiceInput(),
        photoTaker: widget.photoTaker,
      );
      _ownsController = true;
    }
    _textController.text = _controller.state.composerText;
    _messageCount = _controller.state.messages.length;
    _controller.addListener(_onControllerChanged);
    widget.openSessionRequest?.addListener(_onOpenSessionRequest);
    widget.askRequest?.addListener(_onAskRequest);
    // A request made before this screen existed (cold start from a tap)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onOpenSessionRequest();
      _onAskRequest();
    });
    unawaited(_loadSuggestions());
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.openSessionRequest != widget.openSessionRequest) {
      oldWidget.openSessionRequest?.removeListener(_onOpenSessionRequest);
      widget.openSessionRequest?.addListener(_onOpenSessionRequest);
      _onOpenSessionRequest();
    }
    if (oldWidget.askRequest != widget.askRequest) {
      oldWidget.askRequest?.removeListener(_onAskRequest);
      widget.askRequest?.addListener(_onAskRequest);
      _onAskRequest();
    }
  }

  void _onAskRequest() {
    final request = widget.askRequest;
    if (!mounted || request == null) return;
    final question = request.value;
    if (question == null) return;
    request.value = null;
    _controller.newChat();
    _controller.setComposerText(question);
    unawaited(_controller.send(question));
  }

  /// Suggestions from the latest conversations; the defaults stay on any failure.
  Future<void> _loadSuggestions() async {
    final api = _memoryApi;
    if (api == null) return;
    try {
      final recent = await api.listConversations(limit: 10);
      if (mounted) setState(() => _suggestions = chatSuggestions(recent, DateTime.now()));
    } catch (_) {}
  }

  void _onOpenSessionRequest() {
    final request = widget.openSessionRequest;
    if (!mounted || request == null) return;
    final id = request.value;
    if (id == null) return;
    request.value = null;
    unawaited(_controller.loadSession(id));
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final state = _controller.state;
    if (_textController.text != state.composerText) {
      _textController.value = TextEditingValue(
        text: state.composerText,
        selection: TextSelection.collapsed(offset: state.composerText.length),
      );
    }
    if (state.messages.isEmpty && _messageCount > 0) {
      unawaited(_loadSuggestions()); // a new chat: suggest from what happened since
    }
    if (state.messages.length != _messageCount || state.sending) {
      _messageCount = state.messages.length;
      _scrollToBottom();
    }
    setState(() {});
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _openHistory() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ChatHistoryScreen(
          controller: _controller,
          api: _api,
        ),
      ),
    );
  }

  MemoryApi? get _memoryApi {
    final api = _api;
    return widget.memoryApi ?? (api is MemoryApi ? api as MemoryApi : null);
  }

  void _openConversation(String id) {
    unawaited(Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ConversationDetailScreen(conversationId: id, api: _memoryApi!),
      ),
    ));
  }

  void _send() {
    unawaited(_controller.send(_textController.text));
  }

  void _sendSuggestion(String suggestion) {
    _controller.setComposerText(suggestion);
    unawaited(_controller.send(suggestion));
  }

  /// A press shorter than this is a tap: dictation needs the mic held.
  static const _shortestHold = Duration(milliseconds: 400);

  void _voiceEnded(Duration held) {
    unawaited(_controller.stopVoice());
    if (held < _shortestHold && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          key: Key('hold-to-talk-hint'),
          content: Text('Hold the mic while you talk.'),
        ));
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    widget.openSessionRequest?.removeListener(_onOpenSessionRequest);
    widget.askRequest?.removeListener(_onAskRequest);
    _textController.dispose();
    _scrollController.dispose();
    if (_ownsController) _controller.dispose();
    if (_ownsApi) (_api as ApiService).dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final state = _controller.state;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: palette.background,
      body: SafeArea(
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: keyboardInset),
          child: Column(
            children: [
              _Header(
                onHistory: _openHistory,
                onNewChat: _controller.newChat,
              ),
              Divider(height: 1, color: palette.border),
              Expanded(child: _messageArea(state, palette)),
              Divider(height: 1, color: palette.border),
              ChatComposer(
                controller: _textController,
                sending: state.sending,
                listening: state.listening,
                enabled: !state.loadingSession,
                onChanged: _controller.setComposerText,
                onSend: _send,
                onVoiceStart: () => unawaited(_controller.startVoice()),
                onVoiceEnd: _voiceEnded,
                onCamera: _controller.canTakePhotos
                    ? () => unawaited(_controller.takePhoto())
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _messageArea(ChatState state, EchoPalette palette) {
    if (state.loadingSession) {
      return Center(
        key: const Key('chat-session-loading'),
        child: Semantics(
          label: 'Loading chat',
          child: const CircularProgressIndicator(),
        ),
      );
    }

    if (state.messages.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
        children: [
          Text(
            'Ask what your memory knows',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Start with a recent decision, conversation, or task.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: palette.text2,
                ),
          ),
          if (state.error != null) ...[
            const SizedBox(height: 16),
            _ErrorNotice(message: state.error!),
          ],
          const SizedBox(height: 22),
          ..._suggestions.map((suggestion) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OutlinedButton(
                  onPressed: state.sending
                      ? null
                      : () => _sendSuggestion(suggestion),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(suggestion),
                ),
              )),
        ],
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: state.messages.length +
          (state.sending ? 1 : 0) +
          (state.error != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < state.messages.length) {
          final message = state.messages[index];
          return MessageBubble(
            key: message.index == null
                ? ValueKey('user-message-$index')
                : ValueKey('assistant-message-${message.index}'),
            message: message,
            actionBusy: message.pendingAction != null &&
                state.busyActionIds.contains(message.pendingAction!.id),
            onConfirmAction: message.pendingAction == null
                ? null
                : () => unawaited(
                      _controller.confirmAction(message.pendingAction!.id),
                    ),
            onCancelAction: message.pendingAction == null
                ? null
                : () => unawaited(
                      _controller.cancelAction(message.pendingAction!.id),
                    ),
            onFeedback: message.index == null
                ? null
                : (rating) => unawaited(
                      _controller.sendFeedback(message.index!, rating),
                    ),
            onOpenConversation: _memoryApi == null ? null : _openConversation,
            loadPhoto: _api is PhotoApi ? (_api as PhotoApi).photoImage : null,
          );
        }
        if (state.sending && index == state.messages.length) {
          final partial = state.streamingText;
          if (partial != null && partial.isNotEmpty) {
            // The answer as Echo writes it; it becomes a full message when done
            return MessageBubble(
              key: const Key('chat-streaming'),
              message: ChatMessage(text: partial, isUser: false),
            );
          }
          return const Padding(
            key: Key('chat-sending'),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TypingIndicator(),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: _ErrorNotice(
            message: state.error!,
            onRetry: state.canRetry
                ? () => unawaited(_controller.retryLastFailed())
                : state.sessionId == null
                    ? null
                    : () => unawaited(
                          _controller.loadSession(state.sessionId!),
                        ),
          ),
        );
      },
    );
  }
}

final class _Header extends StatelessWidget {
  const _Header({required this.onHistory, required this.onNewChat});

  final VoidCallback onHistory;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const SizedBox(width: 4),
          Text('Ask', style: Theme.of(context).textTheme.titleLarge),
          const Spacer(),
          SizedBox.square(
            dimension: 44,
            child: IconButton(
              key: const Key('chat-history'),
              onPressed: onHistory,
              tooltip: 'Chat history',
              icon: const Icon(Icons.history_rounded),
            ),
          ),
          SizedBox.square(
            dimension: 44,
            child: IconButton(
              key: const Key('chat-new'),
              onPressed: onNewChat,
              tooltip: 'New chat',
              icon: const Icon(Icons.add_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

final class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.error_outline_rounded, color: palette.red, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
          if (onRetry != null)
            TextButton(
              key: const Key('retry-chat-send'),
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}
