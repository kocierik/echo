import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/device_status.dart';
import '../models/segment.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/privacy_control.dart';
import '../widgets/today_memory_preview.dart';
import 'transcript_detail_screen.dart';

typedef LatestMemoryLoader = Future<List<RecentSegment>> Function();

final class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.deviceStatus,
    required this.setMuted,
    required this.onAsk,
    required this.onTranscripts,
    this.onReconnect,
    this.latestMemoryLoader,
    this.api,
    this.segmentUploadedStream,
    this.onMuteAcknowledged,
    super.key,
  });

  final DeviceStatus deviceStatus;
  final Future<void> Function(bool muted) setMuted;
  final Future<void> Function()? onReconnect;
  final VoidCallback onAsk;
  final VoidCallback onTranscripts;
  final LatestMemoryLoader? latestMemoryLoader;
  final ApiService? api;
  final Stream<Object?>? segmentUploadedStream;
  final Future<void> Function()? onMuteAcknowledged;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

final class _HomeScreenState extends State<HomeScreen> {
  static const _muteAcknowledgementTimeout = Duration(seconds: 8);

  late final ApiService _api;
  late final bool _ownsApi;
  StreamSubscription<Object?>? _segmentUploadSubscription;
  Timer? _muteTimeout;
  RecentSegment? _latestMemory;
  String? _memoryError;
  String? _privacyError;
  String? _announcement;
  bool _memoryLoading = true;
  bool _privacyBusy = false;
  bool? _requestedMuted;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    final injectedApi = widget.api;
    _ownsApi = injectedApi == null;
    _api = injectedApi ?? ApiService();
    _subscribeToUploads();
    unawaited(_loadLatestMemory(showLoading: true));
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.segmentUploadedStream != widget.segmentUploadedStream) {
      unawaited(_segmentUploadSubscription?.cancel());
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
    _announcement = requestedMuted
        ? 'Microphone muted'
        : 'Microphone listening resumed';
    setState(() {});
    unawaited(
      (widget.onMuteAcknowledged ?? HapticFeedback.mediumImpact).call(),
    );
  }

  @override
  void dispose() {
    _loadGeneration++;
    _muteTimeout?.cancel();
    unawaited(_segmentUploadSubscription?.cancel());
    if (_ownsApi) _api.dispose();
    super.dispose();
  }

  void _subscribeToUploads() {
    _segmentUploadSubscription = widget.segmentUploadedStream?.listen((_) {
      unawaited(_loadLatestMemory());
    });
  }

  Future<void> _loadLatestMemory({bool showLoading = false}) async {
    final generation = ++_loadGeneration;
    if (showLoading && mounted) {
      setState(() {
        _memoryLoading = true;
        _memoryError = null;
      });
    }

    try {
      final loader = widget.latestMemoryLoader ??
          () => _api.getRecentSegments(limit: 20);
      final segments = await loader();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _latestMemory = segments.cast<RecentSegment?>().firstWhere(
              (segment) =>
                  segment != null &&
                  segment.isCompleted &&
                  stripMemoryPrefix(segment.text ?? '').isNotEmpty,
              orElse: () => null,
            );
        _memoryLoading = false;
        _memoryError = null;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _memoryLoading = false;
        _memoryError = 'Could not load the latest memory.';
      });
    }
  }

  Future<void> _requestMuted(bool muted) async {
    if (_privacyBusy) return;
    setState(() {
      _requestedMuted = muted;
      _privacyBusy = true;
      _privacyError = null;
      _announcement = muted
          ? 'Requesting microphone mute'
          : 'Requesting listening resume';
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

  Future<void> _openLatestMemory() async {
    final segment = _latestMemory;
    if (segment == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TranscriptDetailScreen(segment: segment, api: _api),
      ),
    );
    if (!mounted) return;
    await _loadLatestMemory();
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final presentation = _presentation(widget.deviceStatus.connectionState);
    final visual = _visualFor(presentation, palette);
    final privacyAction = switch (presentation) {
      PrivacyControlPresentation.listening => () => _requestMuted(true),
      PrivacyControlPresentation.muted => () => _requestMuted(false),
      PrivacyControlPresentation.connecting => null,
      PrivacyControlPresentation.offline =>
        widget.onReconnect == null ? null : _reconnect,
    };

    return ColoredBox(
      color: palette.background,
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _TodayHeader(date: DateTime.now()),
                        const SizedBox(height: 20),
                        _DeviceHero(visual: visual),
                        const SizedBox(height: 18),
                        TodayMemoryPreview(
                          loading: _memoryLoading,
                          segment: _latestMemory,
                          error: _memoryError,
                          onRetry: () => unawaited(
                            _loadLatestMemory(showLoading: true),
                          ),
                          onTap: _latestMemory == null
                              ? null
                              : () => unawaited(_openLatestMemory()),
                          onViewAll: widget.onTranscripts,
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.center,
                          child: TextButton.icon(
                            onPressed: widget.onAsk,
                            icon: const Icon(Icons.auto_awesome_outlined),
                            label: const Text('Ask Echo'),
                          ),
                        ),
                        const Spacer(),
                        PrivacyControl(
                          presentation: presentation,
                          onPressed: privacyAction,
                          busy: _privacyBusy,
                          error: _privacyError,
                          onRetry: privacyAction,
                          announcement: _announcement,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

bool _isRequestedTelemetry(DeviceStatus status, bool requestedMuted) {
  return status.connectionState ==
      (requestedMuted
          ? DeviceConnectionState.muted
          : DeviceConnectionState.listening);
}

PrivacyControlPresentation _presentation(DeviceConnectionState state) {
  return switch (state) {
    DeviceConnectionState.listening => PrivacyControlPresentation.listening,
    DeviceConnectionState.muted => PrivacyControlPresentation.muted,
    DeviceConnectionState.scanning ||
    DeviceConnectionState.connecting ||
    DeviceConnectionState.bonding ||
    DeviceConnectionState.reconnecting => PrivacyControlPresentation.connecting,
    DeviceConnectionState.unpaired ||
    DeviceConnectionState.bluetoothOff ||
    DeviceConnectionState.offline ||
    DeviceConnectionState.error => PrivacyControlPresentation.offline,
  };
}

_DeviceVisual _visualFor(
  PrivacyControlPresentation presentation,
  EchoPalette palette,
) {
  return switch (presentation) {
    PrivacyControlPresentation.listening => _DeviceVisual(
        title: 'Listening',
        detail: 'Your microphone is active and private controls are ready.',
        icon: Icons.graphic_eq_rounded,
        color: palette.green,
      ),
    PrivacyControlPresentation.muted => _DeviceVisual(
        title: 'Microphone muted',
        detail: 'Echo is not listening. Resume whenever you are ready.',
        icon: Icons.mic_off_rounded,
        color: palette.red,
      ),
    PrivacyControlPresentation.connecting => _DeviceVisual(
        title: 'Connecting',
        detail: 'Echo is restoring the private device connection.',
        icon: Icons.bluetooth_searching_rounded,
        color: palette.amber,
      ),
    PrivacyControlPresentation.offline => _DeviceVisual(
        title: 'Echo is offline',
        detail: 'Reconnect when the device is nearby and Bluetooth is on.',
        icon: Icons.bluetooth_disabled_rounded,
        color: palette.blue,
      ),
  };
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
        Text('Echo', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(width: 10),
        Text(
          'Today',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: palette.text2,
              ),
        ),
        const Spacer(),
        Text(
          _formatDate(date),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: palette.text2,
              ),
        ),
      ],
    );
  }
}

final class _DeviceHero extends StatelessWidget {
  const _DeviceHero({required this.visual});

  final _DeviceVisual visual;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: '${visual.title}. ${visual.detail}',
      child: SizedBox(
        height: 148,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(visual.icon, size: 48, color: visual.color),
            const SizedBox(height: 12),
            Text(
              visual.title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 6),
            Text(
              visual.detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: EchoPalette.of(context).text2,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _DeviceVisual {
  const _DeviceVisual({
    required this.title,
    required this.detail,
    required this.icon,
    required this.color,
  });

  final String title;
  final String detail;
  final IconData icon;
  final Color color;
}

String _formatDate(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[value.month - 1]} ${value.day}';
}
