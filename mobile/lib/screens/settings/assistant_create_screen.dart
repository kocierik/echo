import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/assistant.dart';
import '../../services/api/api_exception.dart';
import '../../services/api/assistants_api.dart';
import '../../services/api/memory_items_api.dart';
import '../../services/app/spoken_language.dart';
import '../../services/chat/voice_input.dart';
import '../../theme/app_theme.dart';
import 'assistant_editor_screen.dart';

/// New assistant, said aloud: one thing at a time, the voice first.
///
/// 1. The question and a large microphone ("Type it instead" and the examples below).
/// 2. While the user speaks, their words, large.
/// 3. Their words (to correct), Create it and, on the right, the microphone to add more.
/// 4. What Echo wrote: its name and instructions, changed in place, and Save. "Say it
///    again" goes back to 3; "More settings" opens the full editor (emoji, notes,
///    documents). Pops true once saved.
final class AssistantCreateScreen extends StatefulWidget {
  const AssistantCreateScreen({
    required this.api,
    required this.documents,
    this.voiceInput,
    this.language,
    super.key,
  });

  final AssistantsApi api;
  final DocumentsApi documents;

  /// The phone's dictation (replaced in the tests).
  final VoiceInput? voiceInput;

  /// The language dictation hears ("it", "en"); else the account's, kept on the phone.
  final String? language;

  @override
  State<AssistantCreateScreen> createState() => _AssistantCreateScreenState();
}

final class _AssistantCreateScreenState extends State<AssistantCreateScreen> {
  final _description = TextEditingController();
  final _descriptionFocus = FocusNode();
  final _name = TextEditingController();
  final _instructions = TextEditingController();
  List<AssistantTemplate> _templates = const [];
  AssistantTemplate? _template;

  /// What Echo wrote; its name and instructions are in [_name] and [_instructions].
  AssistantDraft? _proposal;

  /// "Type it instead": the words before any were said.
  bool _typing = false;
  bool _writing = false;
  bool _saving = false;
  String? _error;

  late final VoiceInput _voice = widget.voiceInput ?? SpeechToTextVoiceInput();
  bool _listening = false;

  /// What was there when dictation started: what is said goes after it.
  String _before = '';

  bool get _hasWords => _description.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _description.addListener(() => setState(() {}));
    _name.addListener(() => setState(() {}));
    unawaited(_loadTemplates());
  }

  @override
  void dispose() {
    if (_listening) unawaited(_voice.cancel());
    _description.dispose();
    _descriptionFocus.dispose();
    _name.dispose();
    _instructions.dispose();
    super.dispose();
  }

  Future<void> _loadTemplates() async {
    try {
      final templates = await widget.api.assistantTemplates();
      if (mounted) setState(() => _templates = templates);
    } catch (_) {
      // Only the examples are missing: saying it still works
    }
  }

  /// Tap and talk: what is said goes into the words as it is heard; a tap stops it.
  Future<void> _dictate() async {
    if (_listening) {
      await _voice.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _error = null);
    if (!await _voice.request()) {
      if (mounted) {
        setState(() => _error =
            'Dictation is off: allow the Microphone and Speech Recognition for Echo in Settings.');
      }
      return;
    }
    _before = _description.text.trim();
    void heard(String words) {
      if (!mounted) return;
      final text = [if (_before.isNotEmpty) _before, words.trim()].join(' ');
      _description.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }

    setState(() => _listening = true);
    await _voice.start(
      onPartial: heard,
      onFinal: (words) {
        heard(words);
        if (mounted) setState(() => _listening = false);
      },
      // The account's language, not the phone's (an English phone heard Italian as English)
      language: await _spokenLanguage(),
    );
  }

  Future<String?> _spokenLanguage() async {
    final given = widget.language;
    if (given != null) return given;
    try {
      return (await SharedPreferences.getInstance()).getString(SpokenLanguageStore.key);
    } catch (_) {
      return null;
    }
  }

  void _type() {
    setState(() => _typing = true);
    _descriptionFocus.requestFocus();
  }

  /// An example: its text as the words, to change or add to.
  void _example(AssistantTemplate template) {
    setState(() {
      _template = template;
      _description.text = template.instructions;
    });
  }

  Future<void> _write() async {
    if (_listening) {
      await _voice.stop();
      if (mounted) setState(() => _listening = false);
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _writing = true;
      _error = null;
    });
    try {
      final proposal = await widget.api.composeAssistant(
        template: _template?.key,
        topic: _hasWords ? _description.text.trim() : null,
      );
      if (!mounted) return;
      setState(() {
        _proposal = proposal;
        _name.text = proposal.name;
        _instructions.text = proposal.instructions;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = userMessage(error, 'Echo could not write it. Try again.'));
      }
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  /// The proposal as it is now: the name and instructions as changed here.
  AssistantDraft _current() {
    final proposal = _proposal!;
    return AssistantDraft(
      name: _name.text.trim(),
      emoji: proposal.emoji,
      instructions: _instructions.text.trim(),
      notes: proposal.notes,
    );
  }

  Future<void> _save() async {
    final draft = _current();
    if (draft.name.isEmpty || draft.instructions.isEmpty) {
      setState(() => _error = 'Give it a name and instructions.');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.createAssistant(draft);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = userMessage(error, 'Could not save it.');
        });
      }
    }
  }

  /// Back to the words, as they were said: to say more, or differently.
  void _again() => setState(() {
        _proposal = null;
        _error = null;
      });

  /// The full editor (emoji, notes, documents); saved there, this screen is done too.
  Future<void> _moreSettings() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AssistantEditorScreen(
          api: widget.api,
          documents: widget.documents,
          proposal: _current(),
        ),
      ),
    );
    if (saved == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: const Text('New assistant')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 16),
          child: _proposal != null
              ? _proposalStep(context)
              : (_hasWords || _typing || _listening)
                  ? _wordsStep(context)
                  : _startStep(context),
        ),
      ),
    );
  }

  Widget _errorLine(BuildContext context) {
    final error = _error;
    if (error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        error,
        key: const Key('create-error'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: EchoPalette.of(context).red,
            ),
      ),
    );
  }

  /// 1. The question, and the microphone in the middle.
  Widget _startStep(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'What should it do for you?',
          style: textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            height: 1.15,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Say it like you’d tell a friend: the topic, what to keep track of, how to '
          'answer.',
          style: textTheme.bodyMedium?.copyWith(color: palette.text2, height: 1.45),
        ),
        Expanded(
          child: Center(
            child: _BigMic(listening: false, onTap: () => unawaited(_dictate())),
          ),
        ),
        _errorLine(context),
        TextButton(
          key: const Key('create-type'),
          onPressed: _type,
          child: const Text('Type it instead'),
        ),
        if (_templates.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Or start from an example',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: palette.text2),
          ),
          const SizedBox(height: 2),
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              for (final template in _templates)
                TextButton(
                  key: Key('create-example-${template.key}'),
                  style: TextButton.styleFrom(
                    foregroundColor: palette.text,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _example(template),
                  child: Text(template.name),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// 2 and 3. The words, large; while speaking the microphone stays in the middle, after
  /// it Create it and, on the right, the microphone to add more.
  Widget _wordsStep(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'What should it do for you?',
          style: textTheme.titleSmall?.copyWith(color: palette.text2),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            child: TextField(
              key: const Key('create-description'),
              controller: _description,
              focusNode: _descriptionFocus,
              readOnly: _listening,
              minLines: 2,
              maxLines: null,
              maxLength: 2000,
              textCapitalization: TextCapitalization.sentences,
              style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w400, height: 1.4),
              decoration: InputDecoration(
                hintText: _listening ? 'Listening…' : 'Help me with…',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                counterText: '',
              ),
            ),
          ),
        ),
        _errorLine(context),
        if (_listening)
          Center(child: _BigMic(listening: true, onTap: () => unawaited(_dictate())))
        else ...[
          if (_hasWords)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'Tap the words to correct them.',
                style: textTheme.bodySmall?.copyWith(color: palette.text2),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: const Key('create-write'),
                  onPressed: _writing || !_hasWords ? null : () => unawaited(_write()),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  child: Text(_writing ? 'Echo is writing it…' : 'Create it'),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox.square(
                dimension: 52,
                child: IconButton.outlined(
                  key: const Key('create-dictate'),
                  tooltip: 'Say more',
                  onPressed: _writing ? null : () => unawaited(_dictate()),
                  style: IconButton.styleFrom(
                    foregroundColor: palette.accent,
                    side: BorderSide(color: palette.accent, width: 1.5),
                  ),
                  icon: const Icon(Icons.mic_rounded),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 4. What Echo wrote, to change in place, and Save.
  Widget _proposalStep(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final proposal = _proposal!;
    final name = _name.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Container(
              key: const Key('create-proposal'),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(AppTheme.panelRadius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: palette.accentSoft,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(proposal.emoji, style: const TextStyle(fontSize: 24)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          key: const Key('create-name'),
                          controller: _name,
                          maxLength: Assistant.maxName,
                          textCapitalization: TextCapitalization.sentences,
                          style: textTheme.titleMedium,
                          // A field, not a title: its label and a pencil say it changes
                          decoration: InputDecoration(
                            labelText: 'Name',
                            filled: false,
                            counterText: '',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(vertical: 6),
                            border: const UnderlineInputBorder(),
                            enabledBorder: const UnderlineInputBorder(),
                            suffixIcon: Icon(Icons.edit_outlined, size: 18, color: palette.accent),
                            suffixIconConstraints: const BoxConstraints(minWidth: 28),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'What it does',
                          style: textTheme.labelMedium?.copyWith(color: palette.text2),
                        ),
                      ),
                      Icon(Icons.edit_outlined, size: 16, color: palette.accent),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    key: const Key('create-instructions'),
                    controller: _instructions,
                    minLines: 4,
                    maxLines: null,
                    maxLength: Assistant.maxInstructions,
                    textCapitalization: TextCapitalization.sentences,
                    style: textTheme.bodyMedium?.copyWith(height: 1.5),
                    decoration: InputDecoration(
                      counterText: '',
                      contentPadding: const EdgeInsets.all(12),
                      fillColor: palette.background,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: palette.accent, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap the name or the text to change them.',
                    style: textTheme.bodySmall?.copyWith(color: palette.text2),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _errorLine(context),
        FilledButton(
          key: const Key('create-save'),
          onPressed: _saving ? null : () => unawaited(_save()),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: Text(
            _saving ? 'Saving…' : (name.isEmpty ? 'Save' : 'Save $name'),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 4),
        // Side by side, or one under the other with large text
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          children: [
            TextButton(
              key: const Key('create-again'),
              onPressed: _saving ? null : _again,
              child: const Text('Say it again'),
            ),
            TextButton(
              key: const Key('create-more'),
              onPressed: _saving ? null : () => unawaited(_moreSettings()),
              child: const Text('More settings'),
            ),
          ],
        ),
      ],
    );
  }
}

/// The large microphone: "Tap and talk", and while listening a pulse around it (only
/// when the phone allows motion) and "tap to stop".
final class _BigMic extends StatefulWidget {
  const _BigMic({required this.listening, required this.onTap});

  final bool listening;
  final VoidCallback onTap;

  @override
  State<_BigMic> createState() => _BigMicState();
}

final class _BigMicState extends State<_BigMic> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_BigMic old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.listening && !still) {
      if (!_pulse.isAnimating) unawaited(_pulse.repeat());
    } else {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 150,
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, child) => CustomPaint(
              painter: widget.listening ? _RingPainter(_pulse.value, palette.accent) : null,
              child: child,
            ),
            child: Center(
              child: SizedBox.square(
                dimension: 96,
                child: IconButton.filled(
                  key: const Key('create-mic'),
                  tooltip: widget.listening ? 'Stop' : 'Tap and talk',
                  onPressed: widget.onTap,
                  style: IconButton.styleFrom(
                    backgroundColor: palette.accent,
                    foregroundColor: palette.surface,
                  ),
                  icon: Icon(
                    widget.listening ? Icons.stop_rounded : Icons.mic_rounded,
                    size: 40,
                  ),
                ),
              ),
            ),
          ),
        ),
        Text(
          widget.listening ? 'Listening… tap to stop' : 'Tap and talk',
          style: textTheme.titleSmall,
        ),
      ],
    );
  }
}

final class _RingPainter extends CustomPainter {
  _RingPainter(this.t, this.color);

  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (final shift in [0.0, 0.5]) {
      final phase = (t + shift) % 1;
      canvas.drawCircle(
        center,
        48 + 26 * phase,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: 0.45 * (1 - phase)),
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.t != t || old.color != color;
}
