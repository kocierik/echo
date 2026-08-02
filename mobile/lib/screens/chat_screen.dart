import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/chat_message.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/message_bubble.dart';
import '../widgets/typing_indicator.dart';
import 'voice_chat_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _api = ApiService();
  final List<ChatMessage> _messages = [];
  String? _sessionId;
  bool _isTyping = false;
  bool _canSend = false;
  int _msgCount = 0;
  String? _sessionDay; // Track which day this session belongs to

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final canSend = _controller.text.trim().isNotEmpty;
      if (canSend != _canSend) setState(() => _canSend = canSend);
    });
  }

  /// Reset session if it's a new day
  void _ensureFreshDaySession() {
    final today = DateTime.now().toIso8601String().split('T')[0];
    if (_sessionDay != null && _sessionDay != today) {
      // New day — start fresh
      _messages.clear();
      _sessionId = null;
      _msgCount = 0;
    }
    _sessionDay = today;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    _ensureFreshDaySession();
    HapticFeedback.lightImpact();
    setState(() {
      _messages.add(ChatMessage(text: text, isUser: true));
      _isTyping = true;
    });
    _controller.clear();
    _scrollToBottom();

    try {
      final response = await _api.query(text, sessionId: _sessionId);
      _sessionId = response.sessionId;
      _msgCount++;
      setState(() {
        _isTyping = false;
        _messages.add(ChatMessage(text: response.answer, isUser: false, index: _msgCount));
      });
      _scrollToBottom();
    } catch (e) {
      setState(() {
        _isTyping = false;
        _messages.add(ChatMessage(text: 'Error: ${e.toString()}', isUser: false));
      });
    }
  }

  void _onFeedback(int index, String rating) {
    HapticFeedback.selectionClick();
    setState(() {
      _messages.firstWhere((m) => m.index == index).feedback = rating;
    });
    if (_sessionId != null) {
      _api.sendFeedback(sessionId: _sessionId!, messageIndex: index, rating: rating);
    }
  }

  void _newChat() {
    setState(() {
      _messages.clear();
      _sessionId = null;
      _msgCount = 0;
    });
  }

  void _showSessions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SessionsSheet(
        api: _api,
        onSelect: (id) { Navigator.pop(context); _loadSession(id); },
      ),
    );
  }

  Future<void> _loadSession(String id) async {
    // For now just set session ID for follow-up — full history load can come later
    setState(() {
      _messages.clear();
      _sessionId = id;
      _messages.add(ChatMessage(text: 'Session resumed. Ask a follow-up question.', isUser: false));
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
          child: Column(
            children: [
              // App Bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      width: 8, height: 8,
                      decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 10),
                    const Text('Echo', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foreground)),
                    if (_sessionId != null)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: const Text('follow-up', style: TextStyle(fontSize: 10, color: AppColors.foregroundMuted)),
                      ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.add_rounded, color: AppColors.foregroundMuted, size: 22),
                      onPressed: _newChat,
                      tooltip: 'New chat',
                    ),
                    IconButton(
                      icon: const Icon(Icons.history_rounded, color: AppColors.foregroundMuted, size: 22),
                      onPressed: _showSessions,
                      tooltip: 'Sessions',
                    ),
                  ],
                ),
              ),
              // Messages
              Expanded(
                child: _messages.isEmpty
                    ? const Center(
                        child: Text(
                          'Ask your memory anything…',
                          style: TextStyle(color: AppColors.foregroundMuted, fontSize: 15),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        itemCount: _messages.length + (_isTyping ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (i == _messages.length && _isTyping) {
                            return const Align(
                              alignment: Alignment.centerLeft,
                              child: TypingIndicator(),
                            );
                          }
                          final msg = _messages[i];
                          return MessageBubble(
                            message: msg,
                            onFeedback: msg.index != null ? (r) => _onFeedback(msg.index!, r) : null,
                          );
                        },
                      ),
              ),
              // Input
              Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        onSubmitted: (_) => _send(),
                        textInputAction: TextInputAction.send,
                        style: const TextStyle(fontSize: 15),
                        decoration: const InputDecoration(hintText: 'Ask your memory...'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const VoiceChatScreen()),
                      ),
                      icon: const Icon(Icons.mic_none_rounded),
                      tooltip: 'Ask by voice',
                    ),
                    GestureDetector(
                      onTap: _canSend && !_isTyping ? _send : null,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 44, height: 44,
                        decoration: BoxDecoration(
                          color: _canSend ? AppColors.accent : AppColors.surface,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: Icon(
                          Icons.arrow_upward_rounded,
                          color: _canSend ? Colors.white : AppColors.foregroundMuted,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionsSheet extends StatefulWidget {
  final ApiService api;
  final Function(String) onSelect;

  const _SessionsSheet({required this.api, required this.onSelect});

  @override
  State<_SessionsSheet> createState() => _SessionsSheetState();
}

class _SessionsSheetState extends State<_SessionsSheet> {
  List<ChatSession> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sessions = await widget.api.getSessions();
    setState(() { _sessions = sessions; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Sessions', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.foreground)),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_sessions.isEmpty)
            const Text('No sessions yet.', style: TextStyle(color: AppColors.foregroundMuted))
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _sessions.length,
                itemBuilder: (_, i) {
                  final s = _sessions[i];
                  return ListTile(
                    title: Text(s.title, style: const TextStyle(fontSize: 14, color: AppColors.foreground), maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${s.messageCount} messages', style: const TextStyle(fontSize: 12, color: AppColors.foregroundMuted)),
                    contentPadding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    onTap: () => widget.onSelect(s.id),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
