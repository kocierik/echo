import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/skeleton.dart';
import 'conversation_detail_screen.dart';

class AudioScreen extends StatefulWidget {
  const AudioScreen({super.key});

  @override
  State<AudioScreen> createState() => _AudioScreenState();
}

class _AudioScreenState extends State<AudioScreen> {
  final _api = ApiService();
  List<Conversation> _conversations = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final convs = await _api.getConversations();
      setState(() {
        _conversations = convs;
        _loading = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  const Icon(Icons.mic_rounded, color: AppColors.accent, size: 20),
                  const SizedBox(width: 10),
                  Text('Conversations',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Audio captured by your device',
                style: TextStyle(color: AppColors.foregroundMuted, fontSize: 13),
              ),
            ),
            const SizedBox(height: 16),
            // List
            Expanded(
              child: _loading
                  ? const SkeletonList(count: 4)
                  : _error != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.wifi_off_rounded, color: AppColors.foregroundMuted, size: 32),
                              const SizedBox(height: 12),
                              Text('Connection failed', style: const TextStyle(color: AppColors.foregroundMuted, fontSize: 14)),
                              const SizedBox(height: 12),
                              TextButton(
                                onPressed: _load,
                                child: const Text('Retry', style: TextStyle(color: AppColors.accent)),
                              ),
                            ],
                          ),
                        )
                      : _conversations.isEmpty
                          ? const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.mic_off_rounded, color: AppColors.foregroundMuted, size: 32),
                                  SizedBox(height: 12),
                                  Text(
                                    'No conversations yet',
                                    style: TextStyle(color: AppColors.foreground, fontSize: 15, fontWeight: FontWeight.w500),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    'Start recording with your device\nor use the simulator',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: AppColors.foregroundMuted, fontSize: 13),
                                  ),
                                ],
                              ),
                            )
                          : RefreshIndicator(
                              onRefresh: _load,
                              color: AppColors.accent,
                              child: ListView.builder(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                itemCount: _conversations.length,
                                itemBuilder: (_, i) => _ConversationCard(
                                  conversation: _conversations[i],
                                  onTap: () => _openDetail(_conversations[i]),
                                ),
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(Conversation conv) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ConversationDetailScreen(conversationId: conv.id),
      ),
    );
  }
}

class _ConversationCard extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback onTap;

  const _ConversationCard({required this.conversation, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    conversation.title,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.foreground),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _StatusBadge(status: conversation.analysisStatus),
              ],
            ),
            const SizedBox(height: 6),
            if (conversation.summary != null && conversation.summary!.isNotEmpty)
              Text(
                conversation.summary!,
                style: const TextStyle(fontSize: 12, color: AppColors.foregroundMuted, height: 1.4),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.access_time_rounded, size: 12, color: AppColors.foregroundMuted),
                const SizedBox(width: 4),
                Text(
                  _formatDate(conversation.startedAt),
                  style: const TextStyle(fontSize: 11, color: AppColors.foregroundMuted),
                ),
                const SizedBox(width: 12),
                Icon(Icons.segment_rounded, size: 12, color: AppColors.foregroundMuted),
                const SizedBox(width: 4),
                Text(
                  '${conversation.segmentCount} segments',
                  style: const TextStyle(fontSize: 11, color: AppColors.foregroundMuted),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.day}/${dt.month} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final isCompleted = status == 'completed';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isCompleted ? AppColors.success.withOpacity(0.1) : AppColors.surface,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isCompleted ? '✓' : '⏳',
        style: TextStyle(fontSize: 10, color: isCompleted ? AppColors.success : AppColors.foregroundMuted),
      ),
    );
  }
}
