import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/action_models.dart';
import '../models/device_status.dart';
import '../models/memory.dart';
import '../models/person.dart';
import '../models/place.dart';
import '../models/plan.dart';
import '../models/routine_run.dart';
import '../models/task_item.dart';
import '../models/today_insights.dart';
import '../models/today_layout.dart';
import '../services/api/api_exception.dart';
import '../services/api/api_service.dart';
import '../services/app/app_runtime.dart';
import '../services/app/today_layout_store.dart';
import '../services/device/firmware_update.dart';
import '../services/phone/phone_actions.dart';
import '../theme/app_theme.dart';
import '../widgets/coming_up_today.dart';
import '../widgets/echo_nav_bar.dart';
import '../widgets/places_today.dart';
import '../widgets/routine_run_sheet.dart';
import '../widgets/routine_sections.dart';
import '../widgets/screen_header.dart';
import '../widgets/tip_card.dart';
import '../widgets/today_sections.dart';
import '../widgets/today_top_card.dart';
import '../utils/directions.dart';
import '../utils/formatting.dart';
import '../services/memory/memories_controller.dart';
import '../widgets/memory_sections.dart';
import '../widgets/saved_sections.dart';
import 'conversation_detail_screen.dart';
import 'day_screen.dart';
import 'edit_today_screen.dart';
import 'memory_search_screen.dart';
import 'people_screen.dart';
import 'person_screen.dart';
import 'saved_screen.dart';
import 'navigation.dart';
import 'settings/plan_screen.dart';
import 'settings/voice_settings_screen.dart';
import 'task_editing.dart';

/// Today: the day and a greeting, the search over the whole memory, one card for the
/// moment (something to confirm, an event within the hour, the conversation going on,
/// or the day so far), what today's routines found, what to do, a quiet line near and past the speech budget, the day,
/// who came up, what was saved and the days before. Empty sections are left out. The wearable shows up only when something is wrong with it.
final class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.deviceStatus,
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
    this.workingPollInterval = const Duration(seconds: 5),
    this.clock = DateTime.now,
    this.phoneEvents,
    this.memories,
    this.openPerson,
    this.routineRunsChanged,
    this.onOpenThread,
    this.layoutStore,
    this.placesOn,
    this.onOpenPlaces,
    super.key,
  });

  final DeviceStatus deviceStatus;
  final Future<void> Function()? onReconnect;

  /// Opens pairing when no Echo is paired.
  final VoidCallback? onPair;
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

  /// How often "Echo is working on it" is checked while something is working.
  final Duration workingPollInterval;
  final DateTime Function() clock;

  /// The phone calendar's events of the next hour (the app's, unless injected); none
  /// without a calendar, and then no "coming up" card.
  final Future<List<Map<String, Object?>>> Function()? phoneEvents;

  /// The memory (every conversation by day, search, people); its own unless injected.
  final MemoriesController? memories;

  /// Opens a person; returns once their page is closed.
  final ConversationOpener? openPerson;

  /// Counts up when new routine runs arrive: "From your routines" reloads.
  final ValueListenable<int>? routineRunsChanged;

  /// Opens Ask on the thread with Echo (its session id), where "Ask about this" just put
  /// a run.
  final void Function(String sessionId)? onOpenThread;

  /// Where the user's order and hidden sections are kept; the phone's preferences.
  final TodayLayoutStore? layoutStore;

  /// Places visited is on (Profile): today's stays show.
  final ValueListenable<bool>? placesOn;

  /// Places visited, every stay ("See all"); done once it is closed.
  final Future<void> Function()? onOpenPlaces;

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

  // Sections: each loads on its own, so one failure never blanks the screen.
  // The conversations (today's and the days before), search and people come from
  // the memory; the phone's copy of today's shows until it has answered
  late final MemoriesController _memories;
  late final bool _ownsMemories;
  List<ConversationCard> _cachedToday = const [];
  WeeklySummary? _week;
  String? _openId;

  List<TaskItem> _openTasks = const [];
  bool _tasksLoading = true;
  String? _tasksError;
  int _tasksGeneration = 0;

  /// The server recognises voices but has not got the user's own yet.
  bool _ownVoiceMissing = false;

  List<WorkingItem> _working = const [];
  Timer? _workingTimer;

  List<PendingAction> _pending = const [];
  final Set<String> _pendingBusy = {};

  /// The actions and the busy ones, for the "+N more" page while it is open.
  final _pendingView = ValueNotifier<(List<PendingAction>, Set<String>)>((const [], const {}));

  /// The event within the hour and what was said last time, for the agenda.
  ComingUp? _comingUp;

  /// Today's appointments still to come, from the phone's calendar.
  List<TodayEvent> _events = const [];

  /// Today's stays, while Places visited is on.
  List<PlaceVisit> _visits = const [];

  /// The user's order and hidden sections (Edit Today).
  late final TodayLayoutStore _layoutStore = widget.layoutStore ?? TodayLayoutStore();
  TodayLayout _layout = TodayLayout.defaults;

  /// Read once at start; no section shows before it, so a hidden one never flashes.
  late final Future<void> _layoutRead;
  bool _layoutReady = false;

  late final AppLifecycleListener _lifecycle;

  /// A rebuild a minute: the live conversation's time, an appointment that ends.
  Timer? _minuteTimer;

  /// The last line heard in the conversation going on.
  String? _lastLine;

  /// Saved: how many things, and the list one was last saved in (no row without any).
  int _savedTotal = 0;
  String? _savedLatest;

  /// The plan, for the line near and past the speech budget.
  PlanInfo? _plan;

  /// Today's routine runs, for "From your routines".
  List<RoutineRun> _runs = const [];

  @override
  MemoryApi get taskApi => _api;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? (_ownedApi = ApiService());
    _ownsMemories = widget.memories == null;
    _memories = widget.memories ?? MemoriesController(api: _api);
    _memories.addListener(_onMemories);
    unawaited(_memories.initialize());
    _subscribeToUploads();
    widget.routineRunsChanged?.addListener(_onRoutineRuns);
    widget.placesOn?.addListener(_onPlacesOn);
    // Back in the app (often the next morning): what depends on the time of day
    _lifecycle = AppLifecycleListener(onResume: () {
      unawaited(_loadAgenda());
      unawaited(_loadVisits());
      unawaited(_loadRuns());
    });
    _layoutRead = _loadLayout();
    _minuteTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
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
      if (mounted && _memories.state.loading) {
        setState(() => _cachedToday = todayConversations(all, widget.clock()));
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
    if (oldWidget.placesOn != widget.placesOn) {
      oldWidget.placesOn?.removeListener(_onPlacesOn);
      widget.placesOn?.addListener(_onPlacesOn);
    }
    if (oldWidget.routineRunsChanged != widget.routineRunsChanged) {
      oldWidget.routineRunsChanged?.removeListener(_onRoutineRuns);
      widget.routineRunsChanged?.addListener(_onRoutineRuns);
    }
    if (oldWidget.deviceStatus.connectionState != widget.deviceStatus.connectionState &&
        _deviceError != null) {
      setState(() => _deviceError = null);
    }
  }

  @override
  void dispose() {
    widget.routineRunsChanged?.removeListener(_onRoutineRuns);
    widget.placesOn?.removeListener(_onPlacesOn);
    _lifecycle.dispose();
    _minuteTimer?.cancel();
    _pendingView.dispose();
    _memories.removeListener(_onMemories);
    if (_ownsMemories) _memories.dispose();
    _tasksGeneration++;
    _workingTimer?.cancel();
    unawaited(_uploadSubscription?.cancel());
    _ownedApi?.dispose();
    super.dispose();
  }

  void _subscribeToUploads() {
    // New speech changes today's conversations and, after analysis, the tasks
    _uploadSubscription = widget.segmentUploadedStream?.listen((_) {
      unawaited(_memories.refresh());
      unawaited(_loadTasks());
      // A segment may hold "Echo, …": show it as soon as it is being answered
      unawaited(_loadWorking());
    });
  }

  /// Today's conversations: the memory's, or the phone's copy while it loads.
  List<ConversationCard> get _today {
    final state = _memories.state;
    if (state.loading && _cachedToday.isNotEmpty) return _cachedToday;
    return todayConversations(state.conversations, widget.clock());
  }

  /// The days before today, newest first.
  List<List<ConversationCard>> get _earlierDays {
    final today = dayOf(widget.clock());
    final before = _memories.state.conversations
        .where((c) => !c.isOpen && dayOf(c.startedAt).isBefore(today))
        .toList();
    return conversationsByDay(before);
  }

  void _onMemories() {
    if (!mounted) return;
    setState(() {});
    final open = _today.where((c) => c.isOpen).firstOrNull?.id;
    if (open != _openId) {
      _openId = open;
      unawaited(_loadLastLine(_today));
    }
  }

  Future<void> _loadWeek() async {
    final api = _api;
    if (api is! WeeklySummaryApi) return;
    try {
      final week = await (api as WeeklySummaryApi).getLatestWeeklySummary();
      if (mounted) setState(() => _week = week);
    } catch (_) {}
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      _memories.refresh(),
      _memories.loadPeople(),
      _loadWeek(),
      _loadTasks(),
      _loadPending(),
      _loadWorking(),
      _loadOwnVoice(),
      _loadAgenda(),
      _loadVisits(),
      _loadSaved(),
      _loadPlan(),
      _loadRuns(),
    ]);
  }

  void _onRoutineRuns() => unawaited(_loadRuns());

  Future<void> _loadRuns() async {
    final api = _api;
    if (api is! RoutinesApi) return;
    try {
      final page = await (api as RoutinesApi).listRoutineRuns(since: dayOf(widget.clock()));
      if (mounted) setState(() => _runs = page.items);
    } catch (_) {}
  }

  Future<void> _openRun(RoutineRun run) async {
    final api = _api;
    await showRoutineRunSheet(context, run, onAskAbout: () async {
      try {
        final thread = await (api as RoutinesApi).askAboutRoutineRun(run.id);
        widget.onOpenThread?.call(thread);
      } catch (_) {
        if (mounted) _snack('Could not open it in Ask.');
      }
    });
  }

  Future<void> _loadPlan() async {
    final api = _api;
    if (api is! PlanApi) return;
    try {
      final plan = await (api as PlanApi).getPlan();
      if (mounted) setState(() => _plan = plan);
    } catch (_) {}
  }

  Future<void> _openPlan() async {
    final api = _api;
    if (api is! PlanApi) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => PlanScreen(api: api as PlanApi, initial: _plan),
    ));
    if (mounted) await _loadPlan();
  }

  Future<void> _loadSaved() async {
    final api = _api;
    if (api is! SavedApi) return;
    try {
      final saved = await (api as SavedApi).getSaved();
      if (!mounted) return;
      setState(() {
        _savedTotal = saved.total;
        _savedLatest = saved.latestList;
      });
    } catch (_) {}
  }

  Future<void> _openSaved() async {
    final api = _api;
    if (api is! SavedApi) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => SavedScreen(
        api: api as SavedApi,
        loadPhoto: api is PhotoApi ? (api as PhotoApi).photoImage : null,
        onAsk: widget.onAsk,
        openConversation: (context, id) => _openById(id),
        openPerson: (context, id) => _openPerson(id),
        clock: widget.clock,
      ),
    ));
    if (mounted) await _loadSaved();
  }

  Future<void> _loadLayout() async {
    final layout = await _layoutStore.load();
    if (!mounted) return;
    setState(() {
      _layout = layout;
      _layoutReady = true;
    });
  }

  /// What is still to come today on the phone's calendar, and what was said last time
  /// for the event within the hour; nothing without a calendar.
  Future<void> _loadAgenda() async {
    await _layoutRead;
    // Hidden: no calendar read, no recap asked for
    if (!mounted || _layout.isHidden(TodaySection.comingUp)) return;
    final now = widget.clock();
    final endOfDay = DateTime(now.year, now.month, now.day + 1);
    final read = widget.phoneEvents ??
        () async => await _phoneActions?.upcomingEvents(within: endOfDay.difference(now)) ??
            const <Map<String, Object?>>[];
    try {
      final events = await read();
      if (mounted) setState(() => _events = TodayEvent.fromPhone(events, now));
      final api = _api;
      if (api is! ComingUpApi) return;
      final soon = [
        for (final event in events)
          if (DateTime.tryParse(event['start'] as String? ?? '')?.toLocal() case final start?
              when !start.isBefore(now) && start.difference(now) <= const Duration(hours: 1))
            event,
      ];
      final recap = soon.isEmpty ? null : await (api as ComingUpApi).comingUp(soon);
      if (mounted) setState(() => _comingUp = recap);
    } catch (_) {}
  }

  void _onPlacesOn() => unawaited(_loadVisits());

  /// Today's stays, while Places visited is on.
  Future<void> _loadVisits() async {
    await _layoutRead;
    if (!mounted || _layout.isHidden(TodaySection.places)) return;
    final api = _api;
    if (api is! PlacesApi || widget.placesOn?.value != true) {
      if (_visits.isNotEmpty && mounted) setState(() => _visits = const []);
      return;
    }
    try {
      final page = await (api as PlacesApi).listVisits();
      if (mounted) setState(() => _visits = visitsOn(page.visits, widget.clock()));
    } catch (_) {}
  }

  /// The last line heard in the conversation going on, for Your day's live row.
  Future<void> _loadLastLine(List<ConversationCard> today) async {
    final open = today.where((c) => c.isOpen).firstOrNull;
    if (open == null) {
      if (_lastLine != null && mounted) setState(() => _lastLine = null);
      return;
    }
    try {
      final detail = await _api.getConversation(open.id);
      final said = detail.lines.reversed
          .map((line) => line.text == null ? '' : cleanTranscript(line.text!))
          .firstWhere((text) => text.isNotEmpty, orElse: () => '');
      if (mounted) setState(() => _lastLine = said.isEmpty ? null : said);
    } catch (_) {}
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
    final finished = _working.any((old) => !items.any((now) => now.key == old.key));
    setState(() => _working = items);
    if (finished) {
      unawaited(_loadPending());
      unawaited(_loadTasks());
    }
    if (items.isNotEmpty) {
      _workingTimer = Timer(widget.workingPollInterval, () => unawaited(_loadWorking()));
    }
  }

  Future<void> _loadOwnVoice() async {
    final api = _api;
    if (api is! VoiceApi) return;
    try {
      final voices = await (api as VoiceApi).getVoiceProfiles();
      if (mounted) {
        setState(() => _ownVoiceMissing = voices.fingerprintsEnabled && voices.own == null);
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

  /// Pending actions are optional: a failure just shows none.
  Future<void> _loadPending() async {
    try {
      final pending = await _api.listPendingActions();
      if (mounted) _setPending(() => _pending = pending);
    } catch (_) {
      if (mounted) _setPending(() => _pending = const []);
    }
  }

  Future<void> _confirm(PendingAction action) async {
    if (_pendingBusy.contains(action.id)) return;
    _setPending(() => _pendingBusy.add(action.id));
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
      if (mounted) _setPending(() => _pendingBusy.remove(action.id));
    }
  }

  Future<void> _cancel(PendingAction action) async {
    if (_pendingBusy.contains(action.id)) return;
    _setPending(() => _pendingBusy.add(action.id));
    try {
      await _api.cancelPendingAction(action.id);
      if (!mounted) return;
      _replacePending(action.copyWith(status: 'cancelled'));
    } catch (error) {
      if (!mounted) return;
      _snack(userMessage(error, 'Could not cancel this action.'));
      unawaited(_loadPending());
    } finally {
      if (mounted) _setPending(() => _pendingBusy.remove(action.id));
    }
  }

  void _replacePending(PendingAction changed) {
    _setPending(() {
      _pending = [for (final a in _pending) a.id == changed.id ? changed : a];
    });
  }

  void _setPending(VoidCallback change) {
    setState(change);
    _pendingView.value = (_pending, {..._pendingBusy});
  }

  /// "+N more": every action waiting, on a page of its own.
  Future<void> _openPending() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Needs you')),
        body: ValueListenableBuilder<(List<PendingAction>, Set<String>)>(
          valueListenable: _pendingView,
          builder: (context, view, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              NeedsYouSection(
                actions: view.$1,
                busyIds: view.$2,
                onConfirm: (a) => unawaited(_confirm(a)),
                onCancel: (a) => unawaited(_cancel(a)),
              ),
            ],
          ),
        ),
      ),
    ));
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

  Future<void> _openById(String id) async {
    final opener = widget.openConversation;
    if (opener != null) {
      await opener(context, id);
    } else {
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => ConversationDetailScreen(
          conversationId: id,
          api: _api,
          onAsk: widget.onAsk,
          clock: widget.clock,
        ),
      ));
    }
    if (mounted) await _memories.refresh();
  }

  Future<void> _openPerson(String id) async {
    final opener = widget.openPerson;
    if (opener != null) {
      await opener(context, id);
    } else {
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => PersonScreen(
          personId: id,
          api: _api,
          onAsk: widget.onAsk,
          clock: widget.clock,
        ),
      ));
    }
    if (mounted) await _memories.loadPeople();
  }

  Future<void> _openPeople() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => PeopleScreen(
        controller: _memories,
        onOpenPerson: _openPerson,
        now: widget.clock(),
      ),
    ));
  }

  /// A day of "Earlier" (or the whole of today): its digest, then its conversations.
  Future<void> _openDay(List<ConversationCard> conversations) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => DayScreen(
        day: dayOf(conversations.isEmpty ? widget.clock() : conversations.first.startedAt),
        conversations: conversations,
        api: _api,
        onAsk: widget.onAsk,
        openConversation: widget.openConversation,
        clock: widget.clock,
      ),
    ));
  }

  /// Search over the whole memory, on a screen of its own.
  Future<void> _openSearch() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => MemorySearchScreen(
        memories: _memories,
        clock: widget.clock,
        onOpen: (id) => unawaited(_openById(id)),
      ),
    ));
    // Closed: the search is over (not while its screen is torn down)
    _memories.setQuery('');
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
      DeviceConnectionState.offline ||
      DeviceConnectionState.error =>
        widget.onReconnect == null ? null : () => unawaited(_reconnect()),
      _ => null,
    };
  }

  /// One section of Today, empty when it has nothing to show.
  List<Widget> _section(
    TodaySection section, {
    required DateTime now,
    required List<TaskItem> todo,
    required List<ConversationCard> today,
    required bool todayLoading,
    required String? todayError,
    required List<PersonSummary> peopleToday,
    required List<List<ConversationCard>> earlier,
  }) {
    final device = widget.deviceStatus;
    final memory = _memories.state;
    final api = _api;
    return switch (section) {
      TodaySection.routines => [
          RoutinesTodayPanel(runs: _runs, onOpen: (run) => unawaited(_openRun(run))),
        ],
      // Promises are among the to-dos; nothing open at all: no panel
      TodaySection.todo => [
          if (_tasksLoading || _tasksError != null || _openTasks.isNotEmpty) ...[
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
          ],
        ],
      TodaySection.comingUp => [
          ComingUpTodayPanel(
            events: [for (final event in _events) if (event.isLeftOn(now)) event],
            recap: _comingUp,
            now: now,
          ),
        ],
      TodaySection.yourDay => [
          if (todayLoading || todayError != null || today.isNotEmpty) ...[
            YourDayPanel(
              loading: todayLoading,
              conversations: today,
              error: todayError,
              recording: device.connectionState == DeviceConnectionState.listening,
              onRetry: () => unawaited(_memories.refresh()),
              onOpen: (c) => unawaited(_openConversation(c)),
              onSeeAll: () => unawaited(_openDay(today)),
              loadPhoto: api is PhotoApi ? (api as PhotoApi).photoImage : null,
              now: now,
              lastLine: _lastLine,
            ),
            const SizedBox(height: 12),
          ],
        ],
      TodaySection.people => [
          if (peopleToday.isNotEmpty) ...[
            PeoplePanel(
              people: peopleToday,
              onOpen: (id) => unawaited(_openPerson(id)),
              onAll: () => unawaited(_openPeople()),
            ),
            const SizedBox(height: 12),
          ],
        ],
      TodaySection.saved => [
          if (_savedTotal > 0) ...[
            SavedRow(
              total: _savedTotal,
              latestList: _savedLatest,
              onOpen: () => unawaited(_openSaved()),
            ),
            const SizedBox(height: 12),
          ],
        ],
      TodaySection.places => [
          if (widget.placesOn?.value == true)
            PlacesTodayPanel(
              // Filtered again: loaded yesterday, shown this morning
              visits: visitsOn(_visits, now),
              now: now,
              onOpen: (visit) => unawaited(_openVisit(visit)),
              onSeeAll: () => unawaited(_openPlaces()),
            ),
        ],
      TodaySection.earlier => [
          if (_week != null || earlier.isNotEmpty)
            EarlierPanel(
              days: earlier,
              now: now,
              week: _week,
              onOpenWeek: _week == null
                  ? null
                  : () => unawaited(Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => WeekScreen(week: _week!, now: now),
                        ),
                      )),
              onOpenDay: (day) => unawaited(_openDay(day)),
              hasMore: memory.hasMore,
              loadingMore: memory.loadingMore,
              onMore: () => unawaited(_memories.loadMore()),
            ),
          // Its gap like every other section's: Where you've been may come after it
          if (_week != null || earlier.isNotEmpty) const SizedBox(height: 12),
        ],
    };
  }

  /// Edit Today: every change is shown at once and kept on this phone.
  Future<void> _editToday() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => EditTodayScreen(
        layout: _layout,
        onChanged: (layout) {
          final shown = {
            for (final section in TodaySection.values)
              if (_layout.isHidden(section) && !layout.isHidden(section)) section,
          };
          if (mounted) setState(() => _layout = layout);
          unawaited(_layoutStore.save(layout));
          // What a hidden section did not load
          if (shown.contains(TodaySection.comingUp)) unawaited(_loadAgenda());
          if (shown.contains(TodaySection.places)) unawaited(_loadVisits());
        },
      ),
    ));
  }

  /// Places visited; what was deleted there leaves Today too.
  Future<void> _openPlaces() async {
    final open = widget.onOpenPlaces;
    if (open == null) return;
    await open();
    if (mounted) await _loadVisits();
  }

  /// A stay, in the phone's maps.
  Future<void> _openVisit(PlaceVisit visit) async {
    final uri = visitMapsUri(visit, iOS: defaultTargetPlatform == TargetPlatform.iOS);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) _snack('Could not open the map.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final device = widget.deviceStatus;
    final now = widget.clock();
    final todo = editedTasks(todayTodo(_openTasks, now));
    final memory = _memories.state;
    final today = _today;
    final todayLoading = memory.loading && _cachedToday.isEmpty;
    // A failure shows only when there is nothing to show instead
    final todayError = memory.conversations.isEmpty && _cachedToday.isEmpty ? memory.error : null;
    final moment = pickMoment(pending: _pending);
    final peopleToday = peopleSeenOn(memory.people, now);
    final earlier = _earlierDays;

    // A Material, not a ColoredBox: row ink splashes paint on it
    return Material(
      color: palette.background,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The day, no greeting
            ScreenHeader(
              title: '${_weekdays[now.weekday - 1]} ${now.day} ${_months[now.month - 1]}',
              compact: true,
              actions: [
                HeaderIconButton(
                  key: const Key('today-search'),
                  icon: Icons.search_rounded,
                  tooltip: 'Search your memory',
                  onPressed: () => unawaited(_openSearch()),
                ),
                if (widget.headerAction != null) widget.headerAction!,
              ],
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
                          if (update.phase != FirmwareUpdatePhase.available || release == null) {
                            return const SizedBox.shrink();
                          }
                          return TipCard(
                            key: ValueKey('firmware-tip-${release.version}'),
                            tipKey: 'firmware_${release.version}',
                            text: 'A new firmware for Echo (${release.version}) is ready. '
                                'Installing it takes about a minute.',
                            actionLabel: 'Open Echo',
                            onAction: widget.onOpenDevice,
                          );
                        },
                      ),
                    if (moment != null)
                      TodayTopCard(
                        moment: moment,
                        busyIds: _pendingBusy,
                        onConfirm: (a) => unawaited(_confirm(a)),
                        onCancel: (a) => unawaited(_cancel(a)),
                        onMore: () => unawaited(_openPending()),
                      ),
                    // Near and past the speech budget: why the day may come in later
                    if (PlanLine.shows(_plan)) ...[
                      PlanLine(plan: _plan!, onOpen: () => unawaited(_openPlan())),
                      const SizedBox(height: 4),
                    ],
                    for (final section in _layoutReady ? _layout.visible : const <TodaySection>[])
                      ..._section(
                        section,
                        now: now,
                        todo: todo,
                        today: today,
                        todayLoading: todayLoading,
                        todayError: todayError,
                        peopleToday: peopleToday,
                        earlier: earlier,
                      ),
                    Center(
                      child: TextButton.icon(
                        key: const Key('today-edit'),
                        onPressed: () => unawaited(_editToday()),
                        icon: const Icon(Icons.tune_rounded, size: 18),
                        label: const Text('Edit Today'),
                      ),
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
