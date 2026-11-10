import 'dart:async';

import 'package:flutter/material.dart';

import '../models/memory.dart';
import '../services/api/api_exception.dart';
import '../services/api/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/conversation_card.dart';

final class TopicConversationsScreen extends StatefulWidget {
  const TopicConversationsScreen({
    required this.topic,
    required this.api,
    required this.onOpenConversation,
    super.key,
  });

  final String topic;
  final MemoryApi api;
  final Future<void> Function(String id) onOpenConversation;

  @override
  State<TopicConversationsScreen> createState() =>
      _TopicConversationsScreenState();
}

final class _TopicConversationsScreenState
    extends State<TopicConversationsScreen> {
  List<ConversationCard> _conversations = const [];
  String? _error;
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final conversations =
          await widget.api.listConversations(topic: widget.topic);
      if (!mounted || generation != _generation) return;
      setState(() {
        _conversations = conversations;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = userMessage(error, 'Could not load these conversations.');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: Text(widget.topic)),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        TextButton(onPressed: _load, child: const Text('Retry')),
                      ],
                    ),
                  )
                : _conversations.isEmpty
                    ? Center(
                        child: Text(
                          'No conversations about ${widget.topic} yet.',
                          style: TextStyle(color: palette.text2),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(top: 4, bottom: 24),
                        itemCount: _conversations.length,
                        itemBuilder: (context, index) {
                          final conversation = _conversations[index];
                          return ConversationCardTile(
                            conversation: conversation,
                            onTap: () => unawaited(
                              widget.onOpenConversation(conversation.id),
                            ),
                          );
                        },
                      ),
      ),
    );
  }
}
