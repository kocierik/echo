import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/assistant.dart';
import '../../services/api/api_exception.dart';
import '../../services/api/assistants_api.dart';
import '../../services/api/memory_items_api.dart';
import '../../services/chat/voice_input.dart';
import '../../theme/app_theme.dart';
import 'assistant_editor_screen.dart';

/// New assistant, described in words (as Lindy and Gemini's Gems): what it should do for
/// the user, said aloud ("Tell it", the phone's dictation) or typed; a template is a
/// starting text. Echo writes it (name,
/// emoji, instructions, first notes), the user tries it with a question, then saves it,
/// edits it or has it written again. "Write it myself" opens the editor empty. Pops true
/// once saved.
final class AssistantCreateScreen extends StatefulWidget {
  const AssistantCreateScreen({
    required this.api,
    required this.documents,
    this.voiceInput,
    super.key,
  });

  final AssistantsApi api;
  final DocumentsApi documents;

  /// The phone's dictation (replaced in the tests).
  final VoiceInput? voiceInput;

  @override
  State<AssistantCreateScreen> createState() => _AssistantCreateScreenState();
}

final class _AssistantCreateScreenState extends State<AssistantCreateScreen> {
  final _description = TextEditingController();
  final _question = TextEditingController();
  List<AssistantTemplate> _templates = const [];
  AssistantTemplate? _template;
  AssistantDraft? _proposal;
  String? _answer;
  bool _writing = false;
  bool _trying = false;
  bool _saving = false;
  String? _error;

  late final VoiceInput _voice = widget.voiceInput ?? SpeechToTextVoiceInput();
  bool _listening = false;

  /// What was in the field when dictation started: what is said goes after it.
  String _before = '';

  @override
  void initState() {
    super.initState();
    _description.addListener(() => setState(() {}));
    _question.addListener(() => setState(() {}));
    unawaited(_loadTemplates());
  }

  @override
  void dispose() {
    if (_listening) unawaited(_voice.cancel());
    _description.dispose();
    _question.dispose();
    super.dispose();
  }

  Future<void> _loadTemplates() async {
    try {
      final templates = await widget.api.assistantTemplates();
      if (mounted) setState(() => _templates = templates);
    } catch (_) {
      // Only the starting points are missing: the description still works
    }
  }

  /// "Tell it": what is said goes into the description as it is heard; a tap stops it.
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
    );
  }

  /// A template as the starting text, to change; tapped again, it is dropped.
  void _pick(AssistantTemplate template) {
    setState(() {
      if (_template?.key == template.key) {
        _template = null;
      } else {
        _template = template;
        _description.text = template.instructions;
        _description.selection = TextSelection.collapsed(offset: _description.text.length);
      }
    });
  }

  Future<void> _write() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _writing = true;
      _error = null;
      _answer = null;
    });
    try {
      final proposal = await widget.api.composeAssistant(
        template: _template?.key,
        topic: _description.text.trim().isEmpty ? null : _description.text.trim(),
      );
      if (mounted) setState(() => _proposal = proposal);
    } catch (error) {
      if (mounted) {
        setState(() => _error = userMessage(error, 'Echo could not write it. Try again.'));
      }
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<void> _try() async {
    final proposal = _proposal;
    final question = _question.text.trim();
    if (proposal == null || question.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _trying = true;
      _error = null;
    });
    try {
      final answer = await widget.api.tryAssistant(proposal, question);
      if (mounted) setState(() => _answer = answer);
    } catch (error) {
      if (mounted) setState(() => _error = userMessage(error, 'It could not answer. Try again.'));
    } finally {
      if (mounted) setState(() => _trying = false);
    }
  }

  Future<void> _save() async {
    final proposal = _proposal;
    if (proposal == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.createAssistant(proposal);
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

  /// The editor, with the proposal or empty; saved there, this screen is done too.
  Future<void> _edit({AssistantDraft? proposal}) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AssistantEditorScreen(
          api: widget.api,
          documents: widget.documents,
          proposal: proposal,
        ),
      ),
    );
    if (saved == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final proposal = _proposal;
    final busy = _writing || _saving;
    final field = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: palette.border),
    );
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: const Text('New assistant')),
      // The microphone and Create stay at the bottom, in reach of the thumb and above
      // the keyboard; the rest scrolls
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  Text('What should it do for you?', style: textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'Say it aloud or type it, as much as you like: its topic, what to keep track of, '
                    'how to answer. Echo writes the assistant from it.',
                    style: textTheme.bodySmall?.copyWith(color: palette.text2),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('create-description'),
                    controller: _description,
                    minLines: 5,
                    maxLines: 12,
                    maxLength: 2000,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'E.g. Help me with the house: bills and due dates, the weekly '
                          'shopping, chores shared with Olta. Keep the answers short.',
                      contentPadding: const EdgeInsets.all(16),
                      border: field,
                      enabledBorder: field,
                      focusedBorder: field.copyWith(
                        borderSide: BorderSide(color: palette.accent, width: 2),
                      ),
                    ),
                  ),
                  if (_templates.isNotEmpty) ...[
                    Text('Or start from',
                        style: textTheme.labelMedium?.copyWith(color: palette.text2)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final template in _templates)
                          ChoiceChip(
                            key: Key('create-template-${template.key}'),
                            label: Text('${template.emoji} ${template.name}'),
                            selected: _template?.key == template.key,
                            showCheckmark: false,
                            onSelected: busy ? null : (_) => _pick(template),
                          ),
                      ],
                    ),
                  ],
                  if (_error case final error?)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(error, style: textTheme.bodySmall?.copyWith(color: palette.red)),
                    ),
                  if (proposal != null) ...[
                    const SizedBox(height: 20),
                    _Preview(proposal: proposal),
                    const SizedBox(height: 12),
                    _TryIt(
                      question: _question,
                      trying: _trying,
                      answer: _answer,
                      emoji: proposal.emoji,
                      onAsk: () => unawaited(_try()),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            key: const Key('create-edit'),
                            onPressed: busy ? null : () => unawaited(_edit(proposal: proposal)),
                            child: const Text('Edit'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            key: const Key('create-save'),
                            onPressed: busy ? null : () => unawaited(_save()),
                            child: Text(_saving ? 'Saving…' : 'Save'),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextButton(
                    key: const Key('create-myself'),
                    onPressed: busy ? null : () => unawaited(_edit()),
                    child: const Text('Write it myself'),
                  ),
                ],
              ),
            ),
            _BottomBar(
              listening: _listening,
              writing: _writing,
              rewrite: proposal != null,
              onDictate: busy ? null : () => unawaited(_dictate()),
              onWrite: busy || (_description.text.trim().isEmpty && _template == null)
                  ? null
                  : () => unawaited(_write()),
            ),
          ],
        ),
      ),
    );
  }
}

/// At the bottom: the microphone (saying it is quicker than typing it) and Create.
final class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.listening,
    required this.writing,
    required this.rewrite,
    required this.onDictate,
    required this.onWrite,
  });

  final bool listening;
  final bool writing;

  /// A proposal is there: Create writes it again.
  final bool rewrite;
  final VoidCallback? onDictate;
  final VoidCallback? onWrite;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (listening)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Listening… tap to stop',
                style: textTheme.bodySmall?.copyWith(color: palette.accent),
              ),
            ),
          Row(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 60,
                    child: IconButton.filled(
                      key: const Key('create-dictate'),
                      tooltip: listening ? 'Stop' : 'Tell it',
                      onPressed: onDictate,
                      style: IconButton.styleFrom(
                        backgroundColor: listening ? palette.red : palette.accent,
                        foregroundColor: palette.surface,
                      ),
                      icon: Icon(
                        listening ? Icons.stop_rounded : Icons.mic_rounded,
                        size: 30,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    listening ? 'Stop' : 'Tell it',
                    style: textTheme.labelSmall?.copyWith(color: palette.text2),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('create-write'),
                  onPressed: onWrite,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  icon: writing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: Text(
                    writing
                        ? 'Echo is writing it…'
                        : rewrite
                            ? 'Write it again'
                            : 'Create it',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What Echo wrote: the assistant as it will be.
final class _Preview extends StatelessWidget {
  const _Preview({required this.proposal});

  final AssistantDraft proposal;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Container(
      key: const Key('create-preview'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(AppTheme.panelRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
              Expanded(child: Text(proposal.name, style: textTheme.titleMedium)),
            ],
          ),
          const SizedBox(height: 12),
          Text(proposal.instructions, style: textTheme.bodyMedium?.copyWith(height: 1.45)),
          if (proposal.notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('NOTES', style: textTheme.labelSmall?.copyWith(color: palette.text2)),
            const SizedBox(height: 4),
            Text(proposal.notes, style: textTheme.bodySmall?.copyWith(color: palette.text2)),
          ],
        ],
      ),
    );
  }
}

/// Try it: a question, and how the assistant answers it (nothing is kept).
final class _TryIt extends StatelessWidget {
  const _TryIt({
    required this.question,
    required this.trying,
    required this.answer,
    required this.emoji,
    required this.onAsk,
  });

  final TextEditingController question;
  final bool trying;
  final String? answer;
  final String emoji;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Try it', style: textTheme.titleSmall),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('create-question'),
                controller: question,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onAsk(),
                decoration: const InputDecoration(hintText: 'Ask it something'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              key: const Key('create-ask'),
              tooltip: 'Ask',
              onPressed: trying || question.text.trim().isEmpty ? null : onAsk,
              icon: trying
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_upward_rounded),
            ),
          ],
        ),
        if (answer case final text?)
          Container(
            key: const Key('create-answer'),
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: palette.surface2,
              borderRadius: BorderRadius.circular(AppTheme.tileRadius),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(emoji, style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 10),
                Expanded(child: Text(text, style: textTheme.bodyMedium)),
              ],
            ),
          ),
      ],
    );
  }
}
