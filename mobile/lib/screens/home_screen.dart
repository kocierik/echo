import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/action_models.dart';
import '../models/device_status.dart';
import '../models/memory.dart';
import '../models/task_item.dart';
import '../models/today_insights.dart';
import '../services/api_exception.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/device_card.dart';
import '../widgets/privacy_control.dart';
import '../widgets/today_sections.dart';
import 'conversation_detail_screen.dart';
import 'navigation.dart';
import 'task_editing.dart';

/// Today: the wearable, what needs a decision, the day so far, what is due,
/// and the latest daily summary.
final class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.deviceStatus,
    required this.setMuted,
    required this.onOpenMemories,
    required this.onOpenTasks,
    this.onReconnect,
    this.onPair,
    this.onAsk,
    this.api,
    this.segmentUploadedStream,
    this.onMuteAcknowledged,
    this.openConversation,
    this.clock = DateTime.now,
    super.key,
  });

  final DeviceStatus deviceStatus;
  final Future<void> Function(bool muted) setMuted;
  final Future<void> Function()? onReconnect;

  /// Opens pairing when no Echo is paired.
  final VoidCallback? onPair;
  final VoidCallback onOpenMemories;
  final VoidCallback onOpenTasks;
  final AskCallback? onAsk;
  final TodayApi? api;
  final Stream<Object?>? segmentUploadedStream;
  final Future<void> Function()? onMuteAcknowledged;
  final ConversationOpener? openConversation;
  final DateTime Function() clock;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

final class _HomeScreenState extends State<HomeScreen> with TaskEditing {
  static const _muteAcknowledgementTimeout = Duration(seconds: 8);

  late final TodayApi _api;
  ApiService? _ownedApi;
  StreamSubscription<Object?>? _uploadSubscription;

  // Microphone
  Timer? _muteTimeout;
  String? _privacyError;
  String? _announcement;
  bool _privacyBusy = false;
  bool? _requestedMuted;

  // Sections: each loads on its own, so one failure never blanks the screen
  List<ConversationCard> _conversations = const [];
  bool _conversationsLoading = true;
  String? _conversationsError;
  int _conversationsGeneration = 0;

  List<TaskItem> _openTasks = const [];
  bool _tasksLoading = true;
  String? _tasksError;
  int _tasksGeneration = 0;

  DailySummary? _summary;
  bool _summaryLoading = true;
  String? _summaryError;

  List<PendingAction> _pending = const [];
  final Set<String> _pendingBusy = {};

  @override
  MemoryApi get taskApi => _api;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? (_ownedApi = ApiService());
    _subscribeToUploads();
    unawaited(_refreshAll());
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.segmentUploadedStream != widget.segmentUploadedStream) {
      unawaited(_uploadSubscription?.cancel());
      _subscribeToUploads();
    }

    final requestedMuted = _requestedMuted;
    if (requestedMuted == null ||
        oldWidget.deviceStatus == widget.deviceStatus ||
        !_isRequestedTelemetry(widget.deviceStatus, requestedMuted)) {
      return;
    }

    _muteTimeout?.cancel();
    _requestedMuted = null;
    _privacyBusy = false;
    _privacyError = null;
    _announcement = requestedMuted ? 'Microphone muted' : 'Microphone listening resumed';
    setState(() {});
    unawaited((widget.onMuteAcknowledged ?? HapticFeedback.mediumImpact).call());
  }

  @override
  void dispose() {
    _conversationsGeneration++;
    _tasksGeneration++;
    _muteTimeout?.cancel();
    unawaited(_uploadSubscription?.cancel());
    _ownedApi?.dispose();
    super.dispose();
  }

  void _subscribeToUploads() {
    // New speech changes today's conversations and, after analysis, the tasks
    _uploadSubscription = widget.segmentUploadedStream?.listen((_) {
      unawaited(_loadConversations());
      unawaited(_loadTasks());
    });
  }

  Future<void> _refreshAll() async {
    await Future.wait([_loadConversations(), _loadTasks(), _loadSummary(), _loadPending()]);
  }

  Future<void> _loadConversations({bool showLoading = false}) async {
    final generation = ++_conversationsGeneration;
    if (showLoading) {
      setState(() {
        _conversationsLoading = true;
        _conversationsError = null;
      });
    }
    try {
      final all = await _api.listConversations(limit: 30);
      if (!mounted || generation != _conversationsGeneration) return;
      setState(() {
        _conversations = todayConversations(all, widget.clock());
        _conversationsLoading = false;
        _conversationsError = null;
      });
    } catch (error) {
      if (!mounted || generation != _conversationsGeneration) return;
      setState(() {
        _conversationsLoading = false;
        _conversationsError = userMessage(error, "Could not load today's conversations.");
      });
    }
  }

  Future<void> _loadTasks({bool showLoading = false}) async {
    final generation = ++_tasksGeneration;
    if (showLoading) {
      setState(() {
        _tasksLoading = true;
        _tasksError = null;
      });
    }
    try {
      final open = await _api.listTasks(done: false);
      if (!mounted || generation != _tasksGeneration) return;
      setState(() {
        _openTasks = open;
        _tasksLoading = false;
        _tasksError = null;
        resetTaskEdits();
      });
    } catch (error) {
      if (!mounted || generation != _tasksGeneration) return;
      setState(() {
        _tasksLoading = false;
        _tasksError = userMessage(error, 'Could not load tasks.');
      });
    }
  }

  Future<void> _loadSummary() async {
    setState(() => _summaryError = null);
    try {
      final summary = await _api.getLatestDigest();
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _summaryLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _summaryLoading = false;
        _summaryError = userMessage(error, 'Could not load the daily summary.');
      });
    }
  }

  /// Pending actions are optional: a failure just shows none.
  Future<void> _loadPending() async {
    try {
      final pending = await _api.listPendingActions();
      if (mounted) setState(() => _pending = pending);
    } catch (_) {
      if (mounted) setState(() => _pending = const []);
    }
  }

  Future<void> _confirm(PendingAction action) async {
    if (_pendingBusy.contains(action.id)) return;
    setState(() => _pendingBusy.add(action.id));
    try {
      final result = await _api.confirmPendingAction(action.id);
      if (!mounted) return;
      _replacePending(action.copyWith(status: result.status));
      _snack(result.message);
    } catch (error) {
      if (!mounted) return;
      _snack(userMessage(error, 'Could not confirm this action.'));
      unawaited(_loadPending()); // it may have expired or been handled elsewhere
    } finally {
      if (mounted) setState(() => _pendingBusy.remove(action.id));
    }
  }

  Future<void> _cancel(PendingAction action) async {
    if (_pendingBusy.contains(action.id)) return;
    setState(() => _pendingBusy.add(action.id));
    try {
      await _api.cancelPendingAction(action.id);
      if (!mounted) return;
      _replacePending(action.copyWith(status: 'cancelled'));
    } catch (error) {
      if (!mounted) return;
      _snack(userMessage(error, 'Could not cancel this action.'));
      unawaited(_loadPending());
    } finally {
      if (mounted) setState(() => _pendingBusy.remove(action.id));
    }
  }

  void _replacePending(PendingAction changed) {
    setState(() {
      _pending = [for (final a in _pending) a.id == changed.id ? changed : a];
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openConversation(ConversationCard conversation) async {
    final opener = widget.openConversation;
    if (opener != null) {
      await opener(context, conversation.id);
    } else {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ConversationDetailScreen(
            conversationId: conversation.id,
            api: _api,
            onAsk: widget.onAsk,
            clock: widget.clock,
          ),
        ),
      );
    }
    if (mounted) await _refreshAll();
  }

  Future<void> _requestMuted(bool muted) async {
    if (_privacyBusy) return;
    setState(() {
      _requestedMuted = muted;
      _privacyBusy = true;
      _privacyError = null;
      _announcement = muted ? 'Requesting microphone mute' : 'Requesting listening resume';
    });

    _muteTimeout?.cancel();
    _muteTimeout = Timer(_muteAcknowledgementTimeout, () {
      if (!mounted || _requestedMuted != muted) return;
      setState(() {
        _requestedMuted = null;
        _privacyBusy = false;
        _privacyError = 'Echo did not confirm the microphone change.';
        _announcement = _privacyError;
      });
    });

    try {
      await widget.setMuted(muted);
    } catch (_) {
      if (!mounted || _requestedMuted != muted) return;
      _muteTimeout?.cancel();
      setState(() {
        _requestedMuted = null;
        _privacyBusy = false;
        _privacyError = 'Echo could not update the microphone.';
        _announcement = _privacyError;
      });
    }
  }

  Future<void> _reconnect() async {
    final reconnect = widget.onReconnect;
    if (reconnect == null || _privacyBusy) return;
    setState(() {
      _privacyBusy = true;
      _privacyError = null;
      _announcement = 'Reconnecting Echo';
    });
    try {
      await reconnect();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _privacyError = 'Echo could not start reconnecting.';
        _announcement = _privacyError;
      });
    } finally {
      if (mounted) setState(() => _privacyBusy = false);
    }
  }

  VoidCallback? _deviceAction(PrivacyControlPresentation presentation) {
    return switch (presentation) {
      PrivacyControlPresentation.listening => () => unawaited(_requestMuted(true)),
      PrivacyControlPresentation.muted => () => unawaited(_requestMuted(false)),
      PrivacyControlPresentation.connecting => null,
      PrivacyControlPresentation.offline =>
        widget.onReconnect == null ? null : () => unawaited(_reconnect()),
      PrivacyControlPresentation.unpaired => widget.onPair,
    };
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final presentation = devicePresentation(widget.deviceStatus.connectionState);
    final now = widget.clock();
    final tasks = editedTasks(todayTasks(_openTasks, now));

    // A Material, not a ColoredBox: row ink splashes paint on it
    return Material(
      color: palette.background,
      child: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _refreshAll,
          child: ListView(
            key: const Key('today'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              _TodayHeader(date: now),
              const SizedBox(height: 16),
              DeviceCard(
                presentation: presentation,
                onAction: _deviceAction(presentation),
                busy: _privacyBusy,
                error: _privacyError,
                announcement: _announcement,
              ),
              const SizedBox(height: 12),
              NeedsYouSection(
                actions: _pending,
                busyIds: _pendingBusy,
                onConfirm: (a) => unawaited(_confirm(a)),
                onCancel: (a) => unawaited(_cancel(a)),
              ),
              TodayRecapSection(
                loading: _conversationsLoading,
                conversations: _conversations,
                error: _conversationsError,
                onRetry: () => unawaited(_loadConversations(showLoading: true)),
                onOpen: (c) => unawaited(_openConversation(c)),
                onSeeAll: widget.onOpenMemories,
              ),
              const SizedBox(height: 8),
              TodayTasksSection(
                loading: _tasksLoading,
                tasks: tasks,
                error: _tasksError,
                busy: isTaskBusy,
                now: now,
                onRetry: () => unawaited(_loadTasks(showLoading: true)),
                onToggle: (t) => unawaited(toggleTask(t)),
                onDismiss: (t) => unawaited(dismissTask(t)),
                onSeeAll: widget.onOpenTasks,
              ),
              const SizedBox(height: 8),
              DigestSection(
                loading: _summaryLoading,
                summary: _summary,
                error: _summaryError,
                onRetry: () => unawaited(_loadSummary()),
                now: now,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

bool _isRequestedTelemetry(DeviceStatus status, bool requestedMuted) {
  return status.connectionState ==
      (requestedMuted ? DeviceConnectionState.muted : DeviceConnectionState.listening);
}

final class _TodayHeader extends StatelessWidget {
  const _TodayHeader({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('Today', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(width: 10),
        // Takes the free space, and gives way on narrow screens
        Expanded(
          child: Text(
            _formatDate(date),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(color: palette.text2),
          ),
        ),
      ],
    );
  }
}

String _formatDate(DateTime value) {
  const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  return '${weekdays[value.weekday - 1]}, ${months[value.month - 1]} ${value.day}';
}
