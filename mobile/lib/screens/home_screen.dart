import 'dart:async';

import 'package:flutter/material.dart';

import '../models/action_models.dart';
import '../models/device_status.dart';
import '../models/memory.dart';
import '../models/task_item.dart';
import '../models/today_insights.dart';
import '../services/api/api_exception.dart';
import '../services/api/api_service.dart';
import '../services/app/app_runtime.dart';
import '../services/device/firmware_update.dart';
import '../services/phone/phone_actions.dart';
import '../services/phone/phone_calendar.dart';
import '../theme/app_theme.dart';
import '../widgets/echo_nav_bar.dart';
import '../widgets/screen_header.dart';
import '../widgets/tip_card.dart';
import '../widgets/today_sections.dart';
import 'conversation_detail_screen.dart';
import 'integrations_screen.dart';
import 'navigation.dart';
import 'settings/automations_settings_screen.dart';
import 'settings/voice_settings_screen.dart';
import 'task_editing.dart';

/// Today: what needs a decision, what to do, the day so far, and the apps Echo
/// can act in. The wearable shows up only when something is wrong with it.
final class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.deviceStatus,
    required this.onOpenMemories,
    required this.onOpenTasks,
    this.onReconnect,
    this.onPair,
    this.onAsk,
    this.api,
    this.phoneActions,
    this.segmentUploadedStream,
    this.openConversation,
    this.onOpenChat,
    this.firmwareUpdate,
    this.onOpenDevice,
    this.headerAction,
    this.manageAppsBuilder,
    this.addAppBuilder,
    this.workingPollInterval = const Duration(seconds: 5),
    this.clock = DateTime.now,
    super.key,
  });

  final DeviceStatus deviceStatus;
  final Future<void> Function()? onReconnect;

  /// Opens pairing when no Echo is paired.
  final VoidCallback? onPair;
  final VoidCallback onOpenMemories;
  final VoidCallback onOpenTasks;
  final AskCallback? onAsk;
  final TodayApi? api;

  /// Reminders and Calendar on this iPhone; the app's, unless injected.
  final PhoneActionsService? phoneActions;
  final Stream<Object?>? segmentUploadedStream;
  final ConversationOpener? openConversation;

  /// Opens the chat an answer goes to (null: the Voice requests chat).
  final void Function(String? sessionId)? onOpenChat;

  /// A newer wearable firmware is announced once per version, with the way to the Echo
  /// screen, where it is installed.
  final FirmwareUpdateController? firmwareUpdate;
  final VoidCallback? onOpenDevice;

  /// The device pill, in the top right.
  final Widget? headerAction;

  /// "Manage" and "Add an app" in "Echo can act in" (injected in tests).
  final WidgetBuilder? manageAppsBuilder;
  final WidgetBuilder? addAppBuilder;

  /// How often "Echo is working on it" is checked while something is working.
  final Duration workingPollInterval;
  final DateTime Function() clock;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

final class _HomeScreenState extends State<HomeScreen> with TaskEditing {
  late final TodayApi _api;
  ApiService? _ownedApi;
  StreamSubscription<Object?>? _uploadSubscription;

  // Reconnecting the wearable
  bool _deviceBusy = false;
  String? _deviceError;

  // Sections: each loads on its own, so one failure never blanks the screen
  List<ConversationCard> _conversations = const [];
  bool _conversationsLoading = true;
  String? _conversationsError;
  int _conversationsGeneration = 0;

  List<TaskItem> _openTasks = const [];
  bool _tasksLoading = true;
  String? _tasksError;
  int _tasksGeneration = 0;

  /// Apps Echo can act in: connected ones, then Reminders and Calendar.
  List<ActsInApp> _apps = const [];

  /// The server recognises voices but has not got the user's own yet.
  bool _ownVoiceMissing = false;

  List<WorkingItem> _working = const [];
  Timer? _workingTimer;

  List<PendingAction> _pending = const [];
  final Set<String> _pendingBusy = {};

  @override
  MemoryApi get taskApi => _api;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? (_ownedApi = ApiService());
    _subscribeToUploads();
    unawaited(_prefillFromPhone());
    unawaited(_refreshAll());
  }

  /// The phone's copy of the last answers, shown at once while the server answers;
  /// whatever arrives from the server replaces it.
  Future<void> _prefillFromPhone() async {
    final api = _api;
    if (api is! ApiService) return;
    final cached = api.cacheView();
    try {
      final all = await cached.listConversations(limit: 30);
      // Still loading: the server has not answered yet
      if (mounted && _conversationsLoading) {
        setState(() {
          _conversations = todayConversations(all, widget.clock());
          _conversationsLoading = false;
        });
      }
    } catch (_) {}
    try {
      final open = await cached.listTasks(done: false);
      if (mounted && _tasksLoading) {
        setState(() {
          _openTasks = open;
          _tasksLoading = false;
        });
      }
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.segmentUploadedStream != widget.segmentUploadedStream) {
      unawaited(_uploadSubscription?.cancel());
      _subscribeToUploads();
    }
    if (oldWidget.deviceStatus.connectionState != widget.deviceStatus.connectionState &&
        _deviceError != null) {
      setState(() => _deviceError = null);
    }
  }

  @override
  void dispose() {
    _conversationsGeneration++;
    _tasksGeneration++;
    _workingTimer?.cancel();
    unawaited(_uploadSubscription?.cancel());
    _ownedApi?.dispose();
    super.dispose();
  }

  void _subscribeToUploads() {
    // New speech changes today's conversations and, after analysis, the tasks
    _uploadSubscription = widget.segmentUploadedStream?.listen((_) {
      unawaited(_loadConversations());
      unawaited(_loadTasks());
      // A segment may hold "Echo, …": show it as soon as it is being answered
      unawaited(_loadWorking());
    });
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      _loadConversations(),
      _loadTasks(),
      _loadPending(),
      _loadWorking(),
      _loadOwnVoice(),
      _loadApps(),
    ]);
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
        _conversationsError =
            userMessage(error, "Could not load today's conversations.");
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

  /// Requests being answered: checked again while there are any; when one finishes,
  /// what it may have changed (actions to confirm, tasks) is reloaded.
  Future<void> _loadWorking() async {
    final api = _api;
    if (api is! VoiceWorkingApi) return;
    _workingTimer?.cancel();
    List<WorkingItem> items;
    try {
      items = await (api as VoiceWorkingApi).getVoiceWorking();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final finished =
        _working.any((old) => !items.any((now) => now.key == old.key));
    setState(() => _working = items);
    if (finished) {
      unawaited(_loadPending());
      unawaited(_loadTasks());
    }
    if (items.isNotEmpty) {
      _workingTimer =
          Timer(widget.workingPollInterval, () => unawaited(_loadWorking()));
    }
  }

  Future<void> _loadOwnVoice() async {
    final api = _api;
    if (api is! VoiceApi) return;
    try {
      final voices = await (api as VoiceApi).getVoiceProfiles();
      if (mounted) {
        setState(() => _ownVoiceMissing =
            voices.fingerprintsEnabled && voices.own == null);
      }
    } catch (_) {}
  }

  Future<void> _recordVoice() async {
    final api = _api;
    if (api is! VoiceApi) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => VoiceSettingsScreen(api: api as VoiceApi),
    ));
    if (mounted) unawaited(_loadOwnVoice());
  }

  PhoneActionsService? get _phoneActions =>
      widget.phoneActions ?? AppRuntime.maybeCoordinator?.phoneActions;

  /// Connected apps and the iPhone's own: a failure (Composio not set up, the
  /// server unreachable) just leaves those out.
  Future<void> _loadApps() async {
    final apps = <ActsInApp>[];
    final api = _api;
    if (api is ToolkitsApi) {
      try {
        final toolkits = await (api as ToolkitsApi).getToolkits();
        apps.addAll([
          for (final toolkit in toolkits.where((t) => t.connected))
            ActsInApp(name: toolkit.name, icon: ActsInApp.iconFor(toolkit.slug)),
        ]);
      } catch (_) {}
    }
    final phone = _phoneActions;
    if (phone != null) {
      for (final (app, name, icon) in const [
        (PhoneApp.reminders, 'Reminders', Icons.checklist_rounded),
        (PhoneApp.calendar, 'Calendar', Icons.event_outlined),
      ]) {
        try {
          if (phone.isOn(app) && await phone.access(app) == PhoneAccess.granted) {
            apps.add(ActsInApp(name: name, icon: icon));
          }
        } catch (_) {}
      }
    }
    if (mounted) setState(() => _apps = apps);
  }

  Future<void> _openApps({required bool add}) async {
    final builder = add ? widget.addAppBuilder : widget.manageAppsBuilder;
    final api = _api;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: builder ??
          (_) => add
              ? IntegrationsScreen(api: api is ApiService ? api : null)
              : AutomationsSettingsScreen(phoneActions: _phoneActions),
    ));
    if (mounted) unawaited(_loadApps());
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
      unawaited(
          _loadPending()); // it may have expired or been handled elsewhere
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

  Future<void> _reconnect() async {
    final reconnect = widget.onReconnect;
    if (reconnect == null || _deviceBusy) return;
    setState(() {
      _deviceBusy = true;
      _deviceError = null;
    });
    try {
      await reconnect();
    } catch (_) {
      if (!mounted) return;
      setState(() => _deviceError = 'Echo could not start reconnecting.');
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
    }
  }

  VoidCallback? _deviceAction(DeviceConnectionState state) {
    return switch (state) {
      DeviceConnectionState.unpaired => widget.onPair,
      DeviceConnectionState.offline || DeviceConnectionState.error =>
        widget.onReconnect == null ? null : () => unawaited(_reconnect()),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final device = widget.deviceStatus;
    final now = widget.clock();
    final todo = editedTasks(todayTodo(_openTasks, now));

    // A Material, not a ColoredBox: row ink splashes paint on it
    return Material(
      color: palette.background,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ScreenHeader(
              overline: _weekdays[now.weekday - 1],
              title: '${now.day} ${_months[now.month - 1]}',
              actions: [if (widget.headerAction != null) widget.headerAction!],
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refreshAll,
                child: ListView(
                  key: const Key('today'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    16,
                    4,
                    16,
                    24 + EchoShellInsets.bottomOf(context),
                  ),
                  children: [
                    if (DeviceProblemPanel.shows(device.connectionState)) ...[
                      DeviceProblemPanel(
                        state: device.connectionState,
                        pendingBytes: device.bufferBytes,
                        onAction: _deviceAction(device.connectionState),
                        busy: _deviceBusy,
                        error: _deviceError,
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_ownVoiceMissing)
                      TipCard(
                        tipKey: 'record_voice',
                        text:
                            'Record your voice once, so Echo knows when you are the one speaking.',
                        actionLabel: 'Record my voice',
                        onAction: () => unawaited(_recordVoice()),
                      ),
                    if (widget.firmwareUpdate != null)
                      ValueListenableBuilder<FirmwareUpdateState>(
                        valueListenable: widget.firmwareUpdate!,
                        builder: (context, update, _) {
                          final release = update.release;
                          if (update.phase != FirmwareUpdatePhase.available ||
                              release == null) {
                            return const SizedBox.shrink();
                          }
                          return TipCard(
                            key: ValueKey('firmware-tip-${release.version}'),
                            tipKey: 'firmware_${release.version}',
                            text:
                                'A new firmware for Echo (${release.version}) is ready. '
                                'Installing it takes about a minute.',
                            actionLabel: 'Open Echo',
                            onAction: widget.onOpenDevice,
                          );
                        },
                      ),
                    WorkingSection(
                      items: _working,
                      onOpen: widget.onOpenChat == null
                          ? null
                          : (item) => widget.onOpenChat!(item.sessionId),
                    ),
                    NeedsYouSection(
                      actions: _pending,
                      busyIds: _pendingBusy,
                      onConfirm: (a) => unawaited(_confirm(a)),
                      onCancel: (a) => unawaited(_cancel(a)),
                    ),
                    TodoPanel(
                      loading: _tasksLoading,
                      tasks: todo,
                      error: _tasksError,
                      busy: isTaskBusy,
                      now: now,
                      onRetry: () => unawaited(_loadTasks(showLoading: true)),
                      onToggle: (t) => unawaited(toggleTask(t)),
                      onDismiss: (t) => unawaited(dismissTask(t)),
                      onSeeAll: widget.onOpenTasks,
                    ),
                    const SizedBox(height: 12),
                    YourDayPanel(
                      loading: _conversationsLoading,
                      conversations: _conversations,
                      error: _conversationsError,
                      recording: device.connectionState == DeviceConnectionState.listening,
                      onRetry: () => unawaited(_loadConversations(showLoading: true)),
                      onOpen: (c) => unawaited(_openConversation(c)),
                      onSeeAll: widget.onOpenMemories,
                    ),
                    const SizedBox(height: 12),
                    ActsInPanel(
                      apps: _apps,
                      onManage: () => unawaited(_openApps(add: false)),
                      onAdd: () => unawaited(_openApps(add: true)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
