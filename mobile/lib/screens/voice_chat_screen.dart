import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/speech_service.dart';
import '../theme/app_theme.dart';

class VoiceChatScreen extends StatefulWidget {
  const VoiceChatScreen({super.key});

  @override
  State<VoiceChatScreen> createState() => _VoiceChatScreenState();
}

class _VoiceChatScreenState extends State<VoiceChatScreen>
    with SingleTickerProviderStateMixin {
  final _api = ApiService();
  final _speech = SpeechService();
  final _textController = TextEditingController();

  bool _isListening = false;
  bool _isProcessing = false;
  bool _speechAvailable = true;
  String _transcript = '';
  String _response = '';
  String? _sessionId;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    await _speech.init();
    setState(() => _speechAvailable = _speech.isAvailable);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _speech.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _startListening() async {
    HapticFeedback.heavyImpact();
    setState(() {
      _isListening = true;
      _transcript = '';
      _response = '';
    });
    _pulseController.repeat(reverse: true);

    await _speech.startListening((text) {
      setState(() => _transcript = text);
    });
  }

  Future<void> _stopListening() async {
    HapticFeedback.mediumImpact();
    _pulseController.stop();
    _pulseController.reset();
    await _speech.stopListening();

    setState(() {
      _isListening = false;
      _isProcessing = true;
    });

    if (_transcript.trim().isEmpty) {
      setState(() => _isProcessing = false);
      return;
    }

    await _processQuery(_transcript.trim());
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    setState(() {
      _transcript = text;
      _response = '';
      _isProcessing = true;
    });
    await _processQuery(text);
  }

  Future<void> _processQuery(String text) async {
    try {
      final response = await _api.query(text, sessionId: _sessionId);
      _sessionId = response.sessionId;
      setState(() {
        _response = response.answer;
        _isProcessing = false;
      });
    } catch (e) {
      setState(() {
        _response = 'Error: $e';
        _isProcessing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                children: [
                  const Text(
                    'Voice',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foreground),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: AppColors.foregroundMuted),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // Response area
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_transcript.isNotEmpty) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Text(
                          _transcript,
                          style: const TextStyle(fontSize: 15, color: AppColors.foreground, height: 1.4),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    if (_isProcessing)
                      const Column(
                        children: [
                          SizedBox(
                            width: 24, height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                          ),
                          SizedBox(height: 12),
                          Text('Thinking...', style: TextStyle(color: AppColors.foregroundMuted, fontSize: 13)),
                        ],
                      ),
                    if (_response.isNotEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.accent.withValues(alpha: 0.2)),
                        ),
                        child: Text(
                          _response,
                          style: const TextStyle(fontSize: 15, color: AppColors.foreground, height: 1.5),
                        ),
                      ),
                    if (_transcript.isEmpty && _response.isEmpty && !_isListening)
                      const Text(
                        'Hold the mic to speak',
                        style: TextStyle(color: AppColors.foregroundMuted, fontSize: 15),
                      ),
                  ],
                ),
              ),
            ),

            // Mic button or text input fallback
            Padding(
              padding: const EdgeInsets.only(bottom: 48),
              child: _speechAvailable
                  ? GestureDetector(
                      onLongPressStart: (_) => _startListening(),
                      onLongPressEnd: (_) => _stopListening(),
                      onTap: () {
                        if (_isListening) {
                          _stopListening();
                        } else {
                          _startListening();
                          Future.delayed(const Duration(seconds: 15), () {
                            if (_isListening) _stopListening();
                          });
                        }
                      },
                      child: AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, child) {
                          final scale = _isListening ? 1.0 + (_pulseController.value * 0.15) : 1.0;
                          return Transform.scale(
                            scale: scale,
                            child: Container(
                              width: 80,
                              height: 80,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: _isListening
                                      ? [AppColors.error, const Color(0xFFFF6B6B)]
                                      : [AppColors.accent, const Color(0xFF7B61FF)],
                                ),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: (_isListening ? AppColors.error : AppColors.accent).withValues(alpha: 0.4),
                                    blurRadius: _isListening ? 24 : 16,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Icon(
                                _isListening ? Icons.stop_rounded : Icons.mic_rounded,
                                color: Colors.white,
                                size: 32,
                              ),
                            ),
                          );
                        },
                      ),
                    )
                  : // Text input fallback for unsupported platforms
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _textController,
                              onSubmitted: (_) => _sendText(),
                              style: const TextStyle(fontSize: 15),
                              decoration: const InputDecoration(hintText: 'Type your request...'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: _sendText,
                            child: Container(
                              width: 44, height: 44,
                              decoration: BoxDecoration(
                                color: AppColors.accent,
                                borderRadius: BorderRadius.circular(22),
                              ),
                              child: const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 20),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),

            // Hint
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Text(
                _speechAvailable
                    ? (_isListening ? 'Listening... tap to stop' : 'Tap or hold to speak')
                    : 'Speech not available on this platform — use text input',
                style: const TextStyle(color: AppColors.foregroundMuted, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
