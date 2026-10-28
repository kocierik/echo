import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_view_state.dart';
import '../models/chat_message.dart';
import '../models/routine_run.dart';
import '../models/today_insights.dart';
import '../models/saved.dart';
import '../services/api/api_service.dart';
import '../services/app/app_controller.dart';
import '../services/app/spoken_language.dart';
import '../services/chat/chat_controller.dart';
import '../services/device/photo_service.dart';
import '../services/chat/voice_input.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_composer.dart';
import '../widgets/echo_nav_bar.dart';
import '../widgets/screen_header.dart';
import '../widgets/today_sections.dart' show workingLabel;
import '../widgets/message_bubble.dart';
import '../widgets/typing_indicator.dart';
import '../utils/chat_suggestions.dart';
import '../utils/formatting.dart';
import 'chat_history_screen.dart';
import 'conversation_detail_screen.dart';
import 'routine_runs_view.dart';
import 'saved_item_screen.dart';

final class ChatScreen extends StatefulWidget {
  const ChatScreen({
    this.controller,
    this.api,
    this.voiceInput,
    this.openSessionRequest,
    this.composerFocusRequest,
    this.askRequest,
    this.memoryApi,
    this.photoTaker,
    this.headerAction,
    this.dictation,
    this.threadUpdates,
    this.askView,
    this.routinesFilter,
    this.routineRunsChanged,
    this.routinesApi,
    this.segmentUploadedStream,
    this.workingPollInterval = const Duration(seconds: 5),
    this.appState,
    super.key,
  });

  final ChatController? controller;

  /// The device pill, in the top right.
  final Widget? headerAction;

  /// True while the navigation's Ask button is held: dictate into the question.
  final ValueListenable<bool>? dictation;

  /// The wearable camera; no camera button without it.
  final PhotoTaker? photoTaker;
  final ChatApi? api;
  final VoiceInput? voiceInput;

  /// A session id to open (set e.g. by a notification tap); the screen loads
  /// it and sets the notifier back to null.
  final ValueNotifier<String?>? openSessionRequest;

  /// True when the session requested is opened to ask something ("Ask about this" on
  /// Today or Profile): it opens with the cursor in the composer. Set back to false.
  final ValueNotifier<bool>? composerFocusRequest;

  /// A question to send in the thread with Echo (or a new chat, without one),
  /// consumed (set to null) once sent.
  final ValueNotifier<String?>? askRequest;

  /// Changes when the thread got messages from elsewhere: reloaded if it is shown.
  final ValueListenable<int>? threadUpdates;

  /// Chat or Routines (the app's, so a notification can open Routines); without one
  /// Ask keeps its own.
  final ValueNotifier<AskView>? askView;

  /// The routine Ask → Routines shows (null: all of them).
  final ValueNotifier<String?>? routinesFilter;

  /// Counts up when new routine runs arrive: Ask → Routines reloads.
  final ValueListenable<int>? routineRunsChanged;

  /// Routines and their runs; the chat API's when it has them. Without them Ask has no
  /// Routines.
  final RoutinesApi? routinesApi;

  /// New speech reached the server: a voice request may be on its way.
  final Stream<Object?>? segmentUploadedStream;

  /// How often "Echo is working on…" is checked while something is working.
  final Duration workingPollInterval;

  /// The app's tabs: opening Ask checks what Echo is working on.
  final ValueListenable<AppViewState>? appState;

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
  late final ValueNotifier<AskView> _view;
  late final bool _ownsView;
  late final ValueNotifier<String?> _filter;
  late final bool _ownsFilter;

  /// Voice requests and photos Echo is answering, shown at the bottom of the thread.
  List<WorkingItem> _working = const [];
  Timer? _workingTimer;
  StreamSubscription<Object?>? _uploads;

  /// Checks left after new speech, while the server has not heard a request yet.
  int _watchChecks = 0;
  bool _askShown = false;
  late final AppLifecycleListener _lifecycle;

  /// About a minute of checks after new speech: the request shows once Echo heard it.
  static const _watchAfterSpeech = Duration(seconds: 60);

  RoutinesApi? get _routinesApi {
    final api = _api;
    return widget.routinesApi ?? (api is RoutinesApi ? api as RoutinesApi : null);
  }
  int _messageCount = 0;

  /// The language the user speaks, for dictation (kept on the phone, else the account's).
  Future<String?> _spokenLanguage() async {
    final api = _api;
    if (api is! AccountApi) return null;
    try {
      final preferences = await SharedPreferences.getInstance();
      return SpokenLanguageStore(api: api as AccountApi, preferences: preferences).current();
    } catch (_) {
      return null;
    }
  }

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
        spokenLanguage: _spokenLanguage,
      );
      _ownsController = true;
    }
    _textController.text = _controller.state.composerText;
    _messageCount = _controller.state.messages.length;
    _controller.addListener(_onControllerChanged);
    widget.openSessionRequest?.addListener(_onOpenSessionRequest);
    widget.askRequest?.addListener(_onAskRequest);
    widget.dictation?.addListener(_onDictation);
    widget.threadUpdates?.addListener(_onThreadUpdate);
    _ownsView = widget.askView == null;
    _view = widget.askView ?? ValueNotifier(AskView.chat);
    _view.addListener(_onView);
    _ownsFilter = widget.routinesFilter == null;
    _filter = widget.routinesFilter ?? ValueNotifier(null);
    _filter.addListener(_onView);
    _uploads = widget.segmentUploadedStream?.listen((_) {
      _watchChecks =
          (_watchAfterSpeech.inMilliseconds / widget.workingPollInterval.inMilliseconds).ceil();
      unawaited(_loadWorking());
    });
    _askShown = widget.appState?.value.selectedTab == AppController.askTab;
    widget.appState?.addListener(_onAppState);
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_loadWorking()));
    unawaited(_loadWorking());
    // A request made before this screen existed (cold start from a tap); else Ask
    // opens on the thread with Echo
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final opening = widget.openSessionRequest?.value != null ||
          widget.askRequest?.value != null;
      _onOpenSessionRequest();
      _onAskRequest();
      final state = _controller.state;
      if (!opening && state.sessionId == null && state.messages.isEmpty) {
        unawaited(_controller.openThread());
      }
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
    if (oldWidget.threadUpdates != widget.threadUpdates) {
      oldWidget.threadUpdates?.removeListener(_onThreadUpdate);
      widget.threadUpdates?.addListener(_onThreadUpdate);
    }
  }

  bool _dictating = false;

  void _onDictation() {
    final holding = widget.dictation?.value ?? false;
    if (!mounted || holding == _dictating) return;
    _dictating = holding;
    unawaited(holding ? _controller.startVoice() : _controller.stopVoice());
  }

  void _onAskRequest() {
    final request = widget.askRequest;
    if (!mounted || request == null) return;
    final question = request.value;
    if (question == null) return;
    request.value = null;
    unawaited(_ask(question));
  }

  /// In the thread with Echo, where everything Echo answers is; a new chat without one.
  Future<void> _ask(String question) async {
    if (!_controller.hasThread) {
      _controller.newChat();
    } else if (!_controller.state.isThread) {
      await _controller.openThread();
    }
    if (!mounted) return;
    _controller.setComposerText(question);
    await _controller.send(question);
  }

  void _onThreadUpdate() {
    if (!mounted) return;
    unawaited(_controller.refreshThread());
    unawaited(_loadWorking());
  }

  void _onAppState() {
    final shown = widget.appState?.value.selectedTab == AppController.askTab;
    if (shown && !_askShown) unawaited(_loadWorking());
    _askShown = shown;
  }

  /// What Echo is working on; checked again while anything is left, and for a while after
  /// new speech.
  Future<void> _loadWorking() async {
    final api = _api;
    if (api is! VoiceWorkingApi) return;
    _workingTimer?.cancel();
    final List<WorkingItem> items;
    try {
      items = await (api as VoiceWorkingApi).getVoiceWorking();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final finished = _working.any((old) => !items.any((now) => now.key == old.key));
    setState(() => _working = items);
    // An answer arrived: the thread has it
    if (finished) unawaited(_controller.refreshThread());
    // Two checks can overlap (a thread update, an upload): one timer, never orphaned
    _workingTimer?.cancel();
    final watching = _watchChecks > 0;
    if (watching) _watchChecks--;
    if (items.isNotEmpty || watching) {
      _workingTimer = Timer(widget.workingPollInterval, () => unawaited(_loadWorking()));
    }
  }

  void _onView() {
    if (mounted) setState(() {});
  }

  /// "Ask about this": the run goes into the thread with Echo, which opens in Chat
  /// with the composer ready for the question.
  Future<void> _askAbout(RoutineRun run) async {
    try {
      final thread = await _routinesApi!.askAboutRoutineRun(run.id);
      if (!mounted) return;
      _view.value = AskView.chat;
      await _controller.loadSession(thread);
      if (mounted) _composerFocus.requestFocus();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Could not open it in Ask.')));
    }
  }

  /// A thing an answer saved, on its page.
  void _openSaved(SavedChip chip) {
    unawaited(Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => SavedItemScreen(
        itemId: chip.id,
        api: _api as SavedApi,
        loadPhoto: _api is PhotoApi ? (_api as PhotoApi).photoImage : null,
        openConversation:
            _memoryApi == null ? null : (context, id) async => _openConversation(id),
      ),
    )));
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
    final focus = widget.composerFocusRequest;
    final ask = focus?.value ?? false;
    focus?.value = false;
    unawaited(_controller.loadSession(id).then((_) {
      if (ask && mounted) _composerFocus.requestFocus();
    }));
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

  final _composerFocus = FocusNode();

  /// Quick follow-ups under a photo's answer, when the server can look at it again.
  bool _followUps(ChatMessage message) =>
      !message.isUser && message.photoId != null && _api is PhotoFollowUpApi;

  /// "Ask more": the composer, for a question about this photo.
  void _askMore(String photoId) {
    _controller.setPhotoContext(photoId);
    _composerFocus.requestFocus();
  }

  void _sendSuggestion(String suggestion) {
    _controller.setComposerText(suggestion);
    unawaited(_controller.send(suggestion));
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    widget.openSessionRequest?.removeListener(_onOpenSessionRequest);
    widget.askRequest?.removeListener(_onAskRequest);
    widget.dictation?.removeListener(_onDictation);
    widget.threadUpdates?.removeListener(_onThreadUpdate);
    _view.removeListener(_onView);
    if (_ownsView) _view.dispose();
    _filter.removeListener(_onView);
    if (_ownsFilter) _filter.dispose();
    _workingTimer?.cancel();
    unawaited(_uploads?.cancel());
    widget.appState?.removeListener(_onAppState);
    _lifecycle.dispose();
    _composerFocus.dispose();
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
    final routinesApi = _routinesApi;
    final routines = routinesApi != null && _view.value == AskView.routines;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: palette.background,
      body: SafeArea(
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          // Above the keyboard, or above the navigation bar
          padding: EdgeInsets.only(
            bottom: keyboardInset > 0 ? keyboardInset : EchoShellInsets.bottomOf(context),
          ),
          child: Column(
            children: [
              ScreenHeader(
                title: 'Ask',
                actions: [
                  if (!routines) ...[
                    HeaderIconButton(
                      key: const Key('chat-history'),
                      icon: Icons.history_rounded,
                      tooltip: 'Chat history',
                      onPressed: () => unawaited(_openHistory()),
                    ),
                    HeaderIconButton(
                      key: const Key('chat-new'),
                      icon: Icons.add_rounded,
                      tooltip: 'New chat',
                      onPressed: _controller.newChat,
                    ),
                  ],
                  if (widget.headerAction != null) widget.headerAction!,
                ],
              ),
              if (routinesApi != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<AskView>(
                      key: const Key('ask-view'),
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: AskView.chat, label: Text('Chat')),
                        ButtonSegment(value: AskView.routines, label: Text('Routines')),
                      ],
                      selected: {_view.value},
                      onSelectionChanged: (selected) => _view.value = selected.first,
                    ),
                  ),
                ),
              if (routines)
                Expanded(
                  child: RoutineRunsView(
                    api: routinesApi,
                    routineId: _filter.value,
                    onFilter: (id) => _filter.value = id,
                    onAskAbout: _askAbout,
                    changes: widget.routineRunsChanged,
                  ),
                )
              else
                Expanded(child: _messageArea(state, palette)),
              if (!routines && state.isThread)
                for (final item in _working) _WorkingBubble(item),
              if (!routines && state.photoContext != null && !state.listening)
                _PhotoContextChip(onClear: () => _controller.setPhotoContext(null)),
              if (routines)
                const SizedBox.shrink()
              else if (state.listening)
                DictationPanel(text: state.composerText)
              else
                ChatComposer(
                  focusNode: _composerFocus,
                  hintText: state.photoContext != null
                      ? 'Ask about this photo'
                      : 'Ask about your day',
                  controller: _textController,
                  sending: state.sending,
                  enabled: !state.loadingSession,
                  onChanged: _controller.setComposerText,
                  onSend: _send,
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
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        children: [
          Text(
            'Ask what your memory knows',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Start with a recent decision, conversation, or task.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: palette.text2,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            _controller.canTakePhotos
                ? 'Hold the Ask button to dictate. The camera asks Echo about what you see.'
                : 'Hold the Ask button to dictate.',
            key: const Key('chat-input-hint'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (state.error != null) ...[
            const SizedBox(height: 16),
            // The thread could not load: try it again
            _ErrorNotice(
              message: state.error!,
              onRetry: _controller.hasThread && !state.isThread
                  ? () => unawaited(_controller.openThread())
                  : null,
            ),
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
                    foregroundColor: palette.text,
                    side: BorderSide(color: palette.border),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                  ),
                  child: Text(suggestion),
                ),
              )),
        ],
      );
    }

    final rows = _threadRows(state.messages);
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: rows.length +
          (state.sending ? 1 : 0) +
          (state.error != null ? 1 : 0),
      itemBuilder: (context, row) {
        if (row < rows.length && rows[row].day != null) {
          return _DayLabel(day: rows[row].day!);
        }
        final index = row < rows.length ? rows[row].message! : state.messages.length + row - rows.length;
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
            onOpenConversation: _memoryApi == null ? null : _openConversation,
            loadPhoto: _api is PhotoApi ? (_api as PhotoApi).photoImage : null,
            onTranslate: _followUps(message)
                ? () => unawaited(_controller.translatePhoto(message.photoId!))
                : null,
            onAskMore: _followUps(message) ? () => _askMore(message.photoId!) : null,
            onRemind: _followUps(message)
                ? (when) => unawaited(_controller.remindFromPhoto(when))
                : null,
            onOpenSaved: _api is SavedApi ? _openSaved : null,
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

/// The messages to show, a day's name before each new day: a routine's own instruction
/// is left out (its answer says it is a routine's).
List<({int? message, DateTime? day})> _threadRows(List<ChatMessage> messages) {
  final rows = <({int? message, DateTime? day})>[];
  DateTime? current;
  for (final (index, message) in messages.indexed) {
    if (message.isUser && message.routineId != null) continue;
    final at = message.timestamp;
    if (at != null) {
      final day = dayOf(at);
      if (day != current) {
        current = day;
        rows.add((message: null, day: day));
      }
    }
    rows.add((message: index, day: null));
  }
  return rows;
}

/// Above the composer after "Ask more": the question goes about the photo.
final class _PhotoContextChip extends StatelessWidget {
  const _PhotoContextChip({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InputChip(
          key: const Key('photo-context'),
          avatar: Icon(Icons.photo_outlined, size: 18, color: palette.text2),
          label: const Text('About the photo'),
          onDeleted: onClear,
          deleteButtonTooltipMessage: 'Ask about your day instead',
        ),
      ),
    );
  }
}

/// "Today", "Yesterday", "Mon, Oct 13" between the thread's days.
final class _DayLabel extends StatelessWidget {
  const _DayLabel({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Center(
        child: Semantics(
          header: true,
          child: Text(
            dayLabel(day, DateTime.now()),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
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

/// Echo at work on a voice request or a photo, at the bottom of the thread, until its
/// answer arrives.
final class _WorkingBubble extends StatelessWidget {
  const _WorkingBubble(this.item);

  final WorkingItem item;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Padding(
      key: Key('chat-working-${item.key}'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          const TypingIndicator(),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              workingLabel(item),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text2),
            ),
          ),
        ],
      ),
    );
  }
}
