import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/ble_service.dart';
import '../theme/app_theme.dart';
import 'conversation_detail_screen.dart';

class TranscriptsScreen extends StatefulWidget {
  const TranscriptsScreen({super.key});

  @override
  State<TranscriptsScreen> createState() => _TranscriptsScreenState();
}

class _TranscriptsScreenState extends State<TranscriptsScreen> {
  static const _refreshDelays = <Duration>[
    Duration.zero,
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
  ];

  final _api = ApiService();
  final _refreshTimers = <Timer>[];
  StreamSubscription<int>? _uploadSubscription;
  List<RecentSegment> _segments = [];
  bool _loading = true;
  bool _refreshing = false;
  int _queuedRefreshes = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(showLoading: true);
    _uploadSubscription = bleService.segmentUploadedStream.listen((_) {
      _scheduleRealtimeRefresh();
    });
  }

  @override
  void dispose() {
    _uploadSubscription?.cancel();
    for (final timer in _refreshTimers) {
      timer.cancel();
    }
    super.dispose();
  }

  Future<void> _load({bool showLoading = false}) async {
    if (showLoading && mounted) setState(() => _loading = true);
    if (_refreshing) {
      _queuedRefreshes++;
      return;
    }
    _refreshing = true;
    try {
      final segments = await _api.getRecentSegments();
      if (!mounted) return;
      setState(() {
        _segments = segments;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      _refreshing = false;
      if (_queuedRefreshes > 0 && mounted) {
        _queuedRefreshes--;
        unawaited(_load());
      }
    }
  }

  void _scheduleRealtimeRefresh() {
    for (final delay in _refreshDelays) {
      late final Timer timer;
      timer = Timer(delay, () {
        _refreshTimers.remove(timer);
        unawaited(_load());
      });
      _refreshTimers.add(timer);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.bgBase,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Row(
                children: [
                  Text('Transcripts', style: Theme.of(context).textTheme.headlineMedium),
                  const Spacer(),
                  StreamBuilder<BleConnectionState>(
                    stream: bleService.stateStream,
                    initialData: bleService.state,
                    builder: (_, snapshot) => _LiveBadge(
                      connected: snapshot.data == BleConnectionState.connected,
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'New audio appears here while it is being transcribed.',
                style: TextStyle(color: AppColors.foregroundMuted, fontSize: 13),
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _segments.isEmpty) {
      return _MessageState(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load transcripts',
        message: _error!,
        action: _load,
      );
    }
    if (_segments.isEmpty) {
      return const _MessageState(
        icon: Icons.notes_rounded,
        title: 'No transcripts yet',
        message: 'Connect the wearable and start speaking.',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.accent,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: _segments.length,
        separatorBuilder: (_, __) => const Divider(
          height: 1,
          indent: 20,
          endIndent: 20,
          color: AppColors.border,
        ),
        itemBuilder: (_, index) {
          final segment = _segments[index];
          return _TranscriptRow(
            segment: segment,
            onTap: segment.conversationId == null
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ConversationDetailScreen(
                          conversationId: segment.conversationId!,
                        ),
                      ),
                    ),
          );
        },
      ),
    );
  }
}

class _TranscriptRow extends StatelessWidget {
  const _TranscriptRow({required this.segment, this.onTap});

  final RecentSegment segment;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = _displayText(segment);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 38,
              child: Text(
                _formatTime(segment.recordedAt),
                style: const TextStyle(fontSize: 11, color: AppColors.foregroundMuted),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.45,
                      color: segment.text == null
                          ? AppColors.foregroundMuted
                          : AppColors.foreground,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      _StatusLabel(segment: segment),
                      const SizedBox(width: 10),
                      Text(
                        '${(segment.durationMs / 1000).toStringAsFixed(1)}s',
                        style: const TextStyle(fontSize: 11, color: AppColors.foregroundMuted),
                      ),
                      if (onTap != null) ...[
                        const Spacer(),
                        const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.foregroundMuted),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _displayText(RecentSegment segment) {
    final text = segment.text;
    if (text == null || text.isEmpty) {
      return segment.isFailed ? 'Transcription failed' : 'Transcribing...';
    }
    return text.replaceFirst(RegExp(r'^\[(Tu|Altri)\]\s*'), '');
  }

  static String _formatTime(DateTime value) {
    final local = value.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.segment});

  final RecentSegment segment;

  @override
  Widget build(BuildContext context) {
    if (segment.isPending) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 11,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          SizedBox(width: 5),
          Text('Transcribing', style: TextStyle(fontSize: 11, color: AppColors.accent)),
        ],
      );
    }
    if (segment.isFailed) {
      return const Text('Failed', style: TextStyle(fontSize: 11, color: AppColors.error));
    }
    final speaker = segment.speaker == 'self'
      ? 'You'
      : segment.speaker == 'other'
        ? 'Other'
        : null;
    final label = speaker == null ? 'Completed' : 'Completed · $speaker';
    return Text(label, style: const TextStyle(fontSize: 11, color: AppColors.success));
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: connected ? AppColors.success : AppColors.foregroundMuted,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          connected ? 'Live' : 'Offline',
          style: const TextStyle(fontSize: 12, color: AppColors.foregroundMuted),
        ),
      ],
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Future<void> Function()? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: AppColors.foregroundMuted),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontSize: 15, color: AppColors.foreground)),
            const SizedBox(height: 5),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.foregroundMuted),
            ),
            if (action != null) ...[
              const SizedBox(height: 14),
              TextButton(onPressed: action, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}
