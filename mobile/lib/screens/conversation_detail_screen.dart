import 'dart:async';

import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/ble_service.dart';
import '../theme/app_theme.dart';

class ConversationDetailScreen extends StatefulWidget {
  final String conversationId;

  const ConversationDetailScreen({super.key, required this.conversationId});

  @override
  State<ConversationDetailScreen> createState() => _ConversationDetailScreenState();
}

class _ConversationDetailScreenState extends State<ConversationDetailScreen> {
  final _api = ApiService();
  ConversationDetail? _detail;
  bool _loading = true;
  int _loadGeneration = 0;
  StreamSubscription<int>? _uploadSubscription;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _uploadSubscription = bleService.segmentUploadedStream.listen((_) {
      _load();
      _refreshTimer?.cancel();
      _refreshTimer = Timer(const Duration(seconds: 5), _load);
    });
  }

  @override
  void dispose() {
    _uploadSubscription?.cancel();
    _refreshTimer?.cancel();
    _api.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final detail = await _api.getConversationDetail(widget.conversationId);
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _detail = detail;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bgBase, AppColors.bgDeep],
          ),
        ),
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _detail == null
                  ? const Center(child: Text('Failed to load', style: TextStyle(color: AppColors.error)))
                  : _buildContent(),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final d = _detail!;
    return CustomScrollView(
      slivers: [
        // Back button + title
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: AppColors.foregroundMuted),
                  onPressed: () => Navigator.pop(context),
                ),
                Expanded(
                  child: Text(
                    d.title,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.foreground),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Summary intentionally hidden so the transcript view reflects the raw spoken text.
        // Entities
        if (d.entities.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: d.entities.map((e) => _EntityChip(entity: e)).toList(),
              ),
            ),
          ),
        // Section header
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Text('TRANSCRIPTION', style: TextStyle(fontSize: 11, color: AppColors.foregroundMuted, letterSpacing: 0.5, fontWeight: FontWeight.w500)),
          ),
        ),
        // Transcriptions
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) => _TranscriptItem(transcript: d.transcriptions[i]),
            childCount: d.transcriptions.length,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}

class _EntityChip extends StatelessWidget {
  final EntityItem entity;
  const _EntityChip({required this.entity});

  Color get _color {
    switch (entity.type) {
      case 'person': return AppColors.accent;
      case 'task': return const Color(0xFFFCD34D);
      case 'idea': return AppColors.success;
      case 'event': return const Color(0xFFBF5AF2);
      default: return AppColors.foregroundMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _color.withValues(alpha: 0.3)),
      ),
      child: Text(
        entity.name,
        style: TextStyle(fontSize: 12, color: _color),
      ),
    );
  }
}

class _TranscriptItem extends StatelessWidget {
  final TranscriptEntry transcript;
  const _TranscriptItem({required this.transcript});

  @override
  Widget build(BuildContext context) {
    // Parse speaker tag
    String text = transcript.text;
    Widget? speakerTag;
    if (text.startsWith('[Tu] ')) {
      text = text.substring(5);
      speakerTag = const Text('[You] ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.accent));
    } else if (text.startsWith('[Altri] ')) {
      text = text.substring(8);
      speakerTag = const Text('[Other] ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFBF5AF2)));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _formatTime(transcript.recordedAt),
                style: const TextStyle(fontSize: 11, color: AppColors.foregroundMuted),
              ),
              if (speakerTag != null) ...[const SizedBox(width: 8), speakerTag],
            ],
          ),
          const SizedBox(height: 3),
          Text(
            text,
            style: const TextStyle(fontSize: 14, color: AppColors.foreground, height: 1.5),
          ),
          const SizedBox(height: 6),
          const Divider(color: AppColors.border, height: 1),
        ],
      ),
    );
  }

  String _formatTime(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }
}
