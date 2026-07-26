import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/skeleton.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback onAskTap;
  const HomeScreen({super.key, required this.onAskTap});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = ApiService();
  Map<String, dynamic>? _stats;
  Map<String, dynamic>? _digest;
  List<Conversation> _recentConvs = [];
  List<Map<String, dynamic>> _tasks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final stats = await _api.getStats();
      final convs = await _api.getConversations();
      final today = DateTime.now().toIso8601String().split('T')[0];
      final digest = await _api.getDigest(today);
      final tasks = await _api.getTasks();
      setState(() {
        _stats = stats;
        _recentConvs = convs.take(3).toList();
        _digest = digest;
        _tasks = tasks;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
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
                  // Live indicator (placeholder — will animate when device is connected)
                  _LiveIndicator(),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _greeting(),
                style: const TextStyle(color: AppColors.foregroundMuted, fontSize: 14),
              ),
              const SizedBox(height: 24),

              // Daily Recap Card
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

              // Stats Row
              if (_stats != null) ...[
                const Text('TODAY', style: TextStyle(fontSize: 11, color: AppColors.foregroundMuted, letterSpacing: 0.5, fontWeight: FontWeight.w500)),
                const SizedBox(height: 10),
                _StatsRow(stats: _stats!),
                const SizedBox(height: 24),
              ],

              // Recent Conversations
              if (_recentConvs.isNotEmpty) ...[
                const Text('RECENT', style: TextStyle(fontSize: 11, color: AppColors.foregroundMuted, letterSpacing: 0.5, fontWeight: FontWeight.w500)),
                const SizedBox(height: 10),
                ..._recentConvs.map((c) => _RecentConvCard(conv: c)),
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
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.success.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.success.withOpacity(0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6, height: 6,
              decoration: BoxDecoration(
                color: AppColors.success.withOpacity(0.4 + _controller.value * 0.6),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            const Text('Listening', style: TextStyle(fontSize: 11, color: AppColors.success)),
          ],
        ),
      ),
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
                backgroundColor: AppColors.accent.withOpacity(0.08),
                side: BorderSide(color: AppColors.accent.withOpacity(0.2)),
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

class _StatsRow extends StatelessWidget {
  final Map<String, dynamic> stats;
  const _StatsRow({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _StatChip(label: 'Segments', value: '${stats['segments'] ?? 0}'),
        const SizedBox(width: 8),
        _StatChip(label: 'Entities', value: '${stats['entities'] ?? 0}'),
        const SizedBox(width: 8),
        _StatChip(label: 'Conversations', value: '${stats['conversations'] ?? 0}'),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foreground)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 10, color: AppColors.foregroundMuted)),
          ],
        ),
      ),
    );
  }
}

class _RecentConvCard extends StatelessWidget {
  final Conversation conv;
  const _RecentConvCard({required this.conv});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: AppColors.accent.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.record_voice_over_rounded, size: 16, color: AppColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(conv.title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.foreground), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text('${conv.segmentCount} segments', style: const TextStyle(fontSize: 11, color: AppColors.foregroundMuted)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.foregroundMuted),
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
        border: Border.all(color: isDone ? AppColors.success.withOpacity(0.2) : AppColors.border),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: onToggle,
            child: Container(
              width: 22, height: 22,
              decoration: BoxDecoration(
                color: isDone ? AppColors.success.withOpacity(0.15) : Colors.transparent,
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
