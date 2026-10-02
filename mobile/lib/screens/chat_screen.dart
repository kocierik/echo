import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/chat_controller.dart';
import '../services/voice_input.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_composer.dart';
import '../widgets/message_bubble.dart';
import '../widgets/typing_indicator.dart';
import 'chat_history_screen.dart';

final class ChatScreen extends StatefulWidget {
  const ChatScreen({
    this.controller,
    this.api,
    this.voiceInput,
    super.key,
  });

  final ChatController? controller;
  final ChatApi? api;
  final VoiceInput? voiceInput;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

final class _ChatScreenState extends State<ChatScreen> {
  static const _suggestions = [
    'What did I decide today?',
    'Summarize my latest conversation.',
    'What tasks did I mention this week?',
  ];

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
      );
      _ownsController = true;
    }
    _textController.text = _controller.state.composerText;
    _messageCount = _controller.state.messages.length;
    _controller.addListener(_onControllerChanged);
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

  void _send() {
    unawaited(_controller.send(_textController.text));
  }

  void _sendSuggestion(String suggestion) {
    _controller.setComposerText(suggestion);
    unawaited(_controller.send(suggestion));
  }

  void _toggleVoice() {
    if (_controller.state.listening) {
      unawaited(_controller.stopVoice());
    } else {
      unawaited(_controller.startVoice());
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
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
                onVoice: _toggleVoice,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _messageArea(ChatState state, EchoPalette palette) {
    if (state.loadingSession) {
      return const Center(
        key: Key('chat-session-loading'),
        child: Semantics(
          label: 'Loading chat',
          child: CircularProgressIndicator(),
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
            onFeedback: message.index == null
                ? null
                : (rating) => unawaited(
                      _controller.sendFeedback(message.index!, rating),
                    ),
          );
        }
        if (state.sending && index == state.messages.length) {
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
