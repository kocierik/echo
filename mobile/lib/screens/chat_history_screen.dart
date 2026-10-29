import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chat_session.dart';
import '../services/api/api_exception.dart';
import '../services/api/api_service.dart';
import '../services/chat/chat_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/panel.dart';

final class ChatHistoryScreen extends StatefulWidget {
  const ChatHistoryScreen({
    required this.controller,
    required this.api,
    super.key,
  });

  final ChatController controller;
  final ChatApi api;

  @override
  State<ChatHistoryScreen> createState() => _ChatHistoryScreenState();
}

final class _ChatHistoryScreenState extends State<ChatHistoryScreen> {
  List<ChatSessionSummary> _sessions = const [];
  bool _loading = true;
  String? _error;
  final Set<String> _deleting = {};
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sessions = await widget.api.getSessions();
      if (!mounted || generation != _generation) return;
      setState(() {
        _sessions = List.unmodifiable(_voiceFirst(sessions));
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = _message(error, 'Could not load chat history.');
      });
    }
  }

  /// The voice-requests session is pinned first; the rest keep server order.
  static List<ChatSessionSummary> _voiceFirst(
    List<ChatSessionSummary> sessions,
  ) {
    return [
      ...sessions.where((session) => session.kind == 'voice'),
      ...sessions.where((session) => session.kind != 'voice'),
    ];
  }

  void _select(ChatSessionSummary session) {
    unawaited(widget.controller.loadSession(session.id));
    Navigator.pop(context);
  }

  Future<void> _confirmDelete(ChatSessionSummary session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
          'Delete "${session.title ?? 'Untitled chat'}" and its history?',
        ),
        actions: [
          TextButton(
            key: const Key('cancel-delete-session'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-delete-session'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    setState(() {
      _deleting.add(session.id);
      _error = null;
    });
    try {
      await widget.controller.deleteSession(session.id);
      if (!mounted) return;
      setState(() {
        _sessions = List.unmodifiable(
          _sessions.where((item) => item.id != session.id),
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _message(error, 'Could not delete this chat.');
      });
    } finally {
      if (mounted) setState(() => _deleting.remove(session.id));
    }
  }

  String _message(Object error, String fallback) {
    if (error is ApiException) return error.message;
    final message = error.toString().replaceFirst('Exception: ', '').trim();
    return message.isEmpty ? fallback : message;
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: const Text('History')),
      body: _body(palette),
    );
  }

  Widget _body(EchoPalette palette) {
    if (_loading) {
      return const Center(
        key: Key('chat-history-list-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_error != null && _sessions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_error!, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              key: const Key('retry-chat-history-list'),
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [
              TextButton(onPressed: () => setState(() => _error = null), child: const Text('Dismiss')),
            ],
          ),
        Expanded(
          child: _sessions.isEmpty
              ? Center(
                  child: Text(
                    'No chat history yet.',
                    style: TextStyle(color: palette.text2),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    final busy = _deleting.contains(session.id);
                    return PanelListRow(
                      index: index,
                      count: _sessions.length,
                      child: ListTile(
                      minTileHeight: 56,
                      leading: session.kind == 'voice'
                          ? Icon(
                              Icons.push_pin,
                              key: ValueKey('pinned-session-${session.id}'),
                              size: 20,
                            )
                          : session.assistant != null
                              ? Text(
                                  session.assistant!.emoji,
                                  key: ValueKey('session-assistant-${session.id}'),
                                  style: const TextStyle(fontSize: 20),
                                )
                              : null,
                      title: Text(
                        session.title ?? 'Untitled chat',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        session.assistant == null
                            ? '${session.messageCount} messages'
                            : '${session.assistant!.name} · ${session.messageCount} messages',
                      ),
                      onTap: busy ? null : () => _select(session),
                      trailing: SizedBox.square(
                        dimension: 44,
                        child: busy
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : IconButton(
                                key: ValueKey('delete-session-${session.id}'),
                                onPressed: () => _confirmDelete(session),
                                tooltip: 'Delete chat',
                                icon: const Icon(Icons.delete_outline_rounded),
                              ),
                      ),
                    ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}