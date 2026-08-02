import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../services/ble_service.dart';
import '../widgets/skeleton.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback onAskTap;
  final VoidCallback onTranscriptsTap;
  final VoidCallback onSettingsTap;

  const HomeScreen({
    super.key,
    required this.onAskTap,
    required this.onTranscriptsTap,
    required this.onSettingsTap,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = ApiService();
  Map<String, dynamic>? _digest;
  List<RecentSegment> _recentSegments = [];
  List<Map<String, dynamic>> _tasks = [];
  bool _loading = true;
  int _loadGeneration = 0;
  StreamSubscription<int>? _segmentUploadSubscription;
  Timer? _delayedRefresh;

  @override
  void initState() {
    super.initState();
    _load();
    _segmentUploadSubscription = bleService.segmentUploadedStream.listen((_) {
      _load();
      _delayedRefresh?.cancel();
      _delayedRefresh = Timer(const Duration(seconds: 4), _load);
    });
  }

  @override
  void dispose() {
    _segmentUploadSubscription?.cancel();
    _delayedRefresh?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    if (mounted && _recentSegments.isEmpty) setState(() => _loading = true);
    try {
      final recentSegments = await _api.getRecentSegments(limit: 3);
      final today = DateTime.now().toIso8601String().split('T')[0];
      final digest = await _api.getDigest(today);
      final tasks = await _api.getTasks();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _recentSegments = recentSegments;
        _digest = digest;
        _tasks = tasks;
        _loading = false;
      });
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.bgBase, AppColors.bgDeep],
        ),
      ),
      child: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          color: AppColors.accent,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
            children: [
              // Header
              Row(
                children: [
                  Container(
                    width: 8, height: 8,
                    decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 10),
                  const Text('Echo', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: AppColors.foreground, letterSpacing: -0.5)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined, size: 20, color: AppColors.foregroundMuted),
                    onPressed: widget.onSettingsTap,
                    tooltip: 'Settings',
                  ),
                  _LiveIndicator(),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _greeting(),
                style: const TextStyle(color: AppColors.foregroundMuted, fontSize: 14),
              ),
              const SizedBox(height: 12),

              Row(
                children: [
                  const Text('LATEST', style: TextStyle(fontSize: 11, color: AppColors.foregroundMuted, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  TextButton(onPressed: widget.onTranscriptsTap, child: const Text('See all')),
                ],
              ),
              if (_loading)
                const SkeletonCard()
              else if (_recentSegments.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Text('Your latest transcripts will appear here.', style: TextStyle(fontSize: 13, color: AppColors.foregroundMuted)),
                )
              else
                ..._recentSegments.map((segment) => _RecentTranscriptPreview(segment: segment)),
              const SizedBox(height: 22),

              if (_loading)
                const SkeletonCard()
              else if (_digest != null)
                _DigestCard(digest: _digest!)
              else
                _EmptyDigestCard(),

              const SizedBox(height: 24),

              // Tasks from conversations
              if (!_loading && _tasks.isNotEmpty) ...[
                Row(
                  children: [
                    const Text('TASKS', style: TextStyle(fontSize: 11, color: AppColors.foregroundMuted, letterSpacing: 0.5, fontWeight: FontWeight.w500)),
                    const Spacer(),
                    Text('${_tasks.length} pending', style: const TextStyle(fontSize: 10, color: AppColors.foregroundMuted)),
                  ],
                ),
                const SizedBox(height: 10),
                ..._tasks.take(5).map((t) => _TaskItem(
                  task: t,
                  onToggle: () => _toggleTask(t),
                )),
                if (_tasks.length > 5)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Center(
                      child: Text(
                        '+ ${_tasks.length - 5} more tasks',
                        style: const TextStyle(fontSize: 12, color: AppColors.accent),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
              ],

            ],
          ),
        ),
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  Future<void> _toggleTask(Map<String, dynamic> task) async {
    final id = task['id'];
    final isDone = task['metadata_']?['done'] == true;
    await _api.updateEntity(id, metadata: {'done': !isDone});
    _load();
  }
}

class _RecentTranscriptPreview extends StatelessWidget {
  const _RecentTranscriptPreview({required this.segment});

  final RecentSegment segment;

  @override
  Widget build(BuildContext context) {
    final text = segment.text?.replaceFirst(RegExp(r'^\[(Tu|Altri)\]\s*'), '');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            segment.isPending ? Icons.sync_rounded : Icons.notes_rounded,
            size: 17,
            color: segment.isPending ? AppColors.accent : AppColors.foregroundMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text == null || text.isEmpty ? 'Transcribing...' : text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: text == null ? AppColors.foregroundMuted : AppColors.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveIndicator extends StatefulWidget {
  @override
  State<_LiveIndicator> createState() => _LiveIndicatorState();
}

class _LiveIndicatorState extends State<_LiveIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BleConnectionState>(
      stream: bleService.stateStream,
      initialData: bleService.state,
      builder: (context, snap) {
        final state = snap.data ?? BleConnectionState.disconnected;
        return GestureDetector(
          onTap: () {
            if (state == BleConnectionState.disconnected) {
              bleService.startScan();
            } else if (state == BleConnectionState.connected) {
              bleService.disconnect();
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: state == BleConnectionState.connected ? AppColors.success.withValues(alpha: 0.08) : AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: state == BleConnectionState.connected ? AppColors.success.withValues(alpha: 0.2) : AppColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  state == BleConnectionState.connected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_disabled_rounded,
                  size: 14,
                  color: state == BleConnectionState.connected ? AppColors.success : AppColors.foregroundMuted,
                ),
                const SizedBox(width: 6),
                Text(
                  state == BleConnectionState.connected ? 'Device' : (state == BleConnectionState.scanning ? 'Scanning...' : 'No device'),
                  style: TextStyle(fontSize: 11, color: state == BleConnectionState.connected ? AppColors.success : AppColors.foregroundMuted),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DigestCard extends StatelessWidget {
  final Map<String, dynamic> digest;
  const _DigestCard({required this.digest});

  @override
  Widget build(BuildContext context) {
    final summary = digest['summary'] ?? '';
    final people = List<String>.from(digest['people'] ?? []);
    final convCount = digest['conversation_count'] ?? 0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome_rounded, size: 16, color: AppColors.accent),
              const SizedBox(width: 8),
              const Text('Daily Recap', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.foreground)),
              const Spacer(),
              Text('$convCount conversations', style: const TextStyle(fontSize: 11, color: AppColors.foregroundMuted)),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            summary,
            style: const TextStyle(fontSize: 14, color: AppColors.foreground, height: 1.5),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          if (people.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              children: people.take(5).map((p) => Chip(
                label: Text(p, style: const TextStyle(fontSize: 11, color: AppColors.accent)),
                backgroundColor: AppColors.accent.withValues(alpha: 0.08),
                side: BorderSide(color: AppColors.accent.withValues(alpha: 0.2)),
                padding: EdgeInsets.zero,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              )).toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyDigestCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: const Column(
        children: [
          Icon(Icons.auto_awesome_outlined, size: 28, color: AppColors.foregroundMuted),
          SizedBox(height: 10),
          Text('No recap yet today', style: TextStyle(fontSize: 14, color: AppColors.foreground, fontWeight: FontWeight.w500)),
          SizedBox(height: 4),
          Text('Start a conversation and your\ndaily recap will appear here', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: AppColors.foregroundMuted)),
        ],
      ),
    );
  }
}

class _TaskItem extends StatelessWidget {
  final Map<String, dynamic> task;
  final VoidCallback onToggle;
  const _TaskItem({required this.task, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final name = task['name'] ?? '';
    final content = task['content'] ?? '';
    final isDone = task['metadata_']?['done'] == true;
    final createdAt = task['created_at'] ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDone ? AppColors.success.withValues(alpha: 0.2) : AppColors.border),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: onToggle,
            child: Container(
              width: 22, height: 22,
              decoration: BoxDecoration(
                color: isDone ? AppColors.success.withValues(alpha: 0.15) : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: isDone ? AppColors.success : AppColors.foregroundMuted, width: 1.5),
              ),
              child: isDone ? const Icon(Icons.check_rounded, size: 14, color: AppColors.success) : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: isDone ? AppColors.foregroundMuted : AppColors.foreground,
                    decoration: isDone ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (content.isNotEmpty)
                  Text(content, style: const TextStyle(fontSize: 11, color: AppColors.foregroundMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (createdAt.isNotEmpty)
            Text(_formatDay(createdAt), style: const TextStyle(fontSize: 10, color: AppColors.foregroundMuted)),
        ],
      ),
    );
  }

  String _formatDay(String iso) {
    try {
      final dt = DateTime.parse(iso);
      final now = DateTime.now();
      if (dt.day == now.day && dt.month == now.month) return 'Today';
      if (dt.day == now.day - 1 && dt.month == now.month) return 'Yesterday';
      return '${dt.day}/${dt.month}';
    } catch (_) {
      return '';
    }
  }
}
