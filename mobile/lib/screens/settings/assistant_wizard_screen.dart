import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/assistant.dart';
import '../../services/api/api_exception.dart';
import '../../services/api/assistants_api.dart';
import '../../services/api/memory_items_api.dart';
import '../../theme/app_theme.dart';
import 'assistant_editor_screen.dart';

/// New assistant, by answering a few questions (as GPT Builder's "Create" and Gemini's
/// Gems): a template asks its own; from scratch, first what it is for, then questions
/// made for that. Echo writes a proposal from the answers, opened in the editor to review
/// before saving; "Write it myself" opens the editor as it is. Pops true once saved.
final class AssistantWizardScreen extends StatefulWidget {
  const AssistantWizardScreen({
    required this.api,
    required this.documents,
    this.template,
    super.key,
  });

  final AssistantsApi api;
  final DocumentsApi documents;

  /// Null: from scratch.
  final AssistantTemplate? template;

  @override
  State<AssistantWizardScreen> createState() => _AssistantWizardScreenState();
}

final class _AssistantWizardScreenState extends State<AssistantWizardScreen> {
  final _topic = TextEditingController();
  List<AssistantQuestion>? _questions;

  /// Per question: the options tapped, and the words.
  final _picked = <String, Set<String>>{};
  final _words = <String, TextEditingController>{};
  bool _busy = false;
  String? _error;

  AssistantTemplate? get _template => widget.template;

  @override
  void initState() {
    super.initState();
    _topic.addListener(() => setState(() {}));
    // A template knows its questions at once; from scratch they wait for the topic
    if (_template != null) unawaited(_loadQuestions());
  }

  @override
  void dispose() {
    _topic.dispose();
    for (final controller in _words.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadQuestions() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final questions = await widget.api.assistantQuestions(
        template: _template?.key,
        topic: _template == null ? _topic.text.trim() : null,
      );
      if (!mounted) return;
      setState(() {
        _questions = questions;
        for (final question in questions) {
          _picked.putIfAbsent(question.id, () => <String>{});
          _words.putIfAbsent(question.id, TextEditingController.new);
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = userMessage(error, 'Could not load the questions.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<(String, String)> get _answers => [
        for (final question in _questions ?? const <AssistantQuestion>[])
          if (_answer(question) case final answer when answer.isNotEmpty)
            (question.text, answer),
      ];

  String _answer(AssistantQuestion question) => [
        ...question.options.where((o) => _picked[question.id]!.contains(o)),
        if (_words[question.id]!.text.trim() case final words when words.isNotEmpty) words,
      ].join(', ');

  void _tapOption(AssistantQuestion question, String option) {
    setState(() {
      final picked = _picked[question.id]!;
      if (picked.contains(option)) {
        picked.remove(option);
      } else {
        if (!question.multi) picked.clear();
        picked.add(option);
      }
    });
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final proposal = await widget.api.composeAssistant(
        template: _template?.key,
        topic: _template == null ? _topic.text.trim() : null,
        answers: _answers,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await _openEditor(proposal: proposal);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = userMessage(error, 'Echo could not write it. Try again.');
        });
      }
    }
  }

  /// The editor with Echo's proposal, or the template (or nothing) as it is.
  Future<void> _openEditor({AssistantDraft? proposal}) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AssistantEditorScreen(
          api: widget.api,
          documents: widget.documents,
          template: proposal == null ? _template : null,
          proposal: proposal,
        ),
      ),
    );
    // Back from the editor without saving: the answers are still here to change
    if (saved == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final template = _template;
    final questions = _questions;
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: const Text('New assistant')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: palette.accentSoft,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(template?.emoji ?? '✨', style: const TextStyle(fontSize: 26)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        template?.name ?? 'From scratch',
                        style: textTheme.titleLarge,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        questions == null && template == null
                            ? 'Say what it is for: Echo asks a few questions about it.'
                            : 'A few answers, and Echo writes it for you. Skip any.',
                        style: textTheme.bodySmall?.copyWith(color: palette.text2),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (template == null && questions == null) ...[
              Text('What should it help you with?', style: textTheme.titleMedium),
              const SizedBox(height: 10),
              TextField(
                key: const Key('wizard-topic'),
                controller: _topic,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                maxLength: 300,
                textCapitalization: TextCapitalization.sentences,
                decoration: _fieldDecoration(
                  palette,
                  'E.g. train for the Bologna half marathon',
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('wizard-next'),
                onPressed: _busy || _topic.text.trim().isEmpty
                    ? null
                    : () => unawaited(_loadQuestions()),
                child: const Text('Next'),
              ),
            ],
            if (questions != null)
              for (final (index, question) in questions.indexed) ...[
                _QuestionCard(
                  key: Key('wizard-question-${question.id}'),
                  number: index + 1,
                  question: question,
                  picked: _picked[question.id]!,
                  words: _words[question.id]!,
                  onTap: (option) => _tapOption(question, option),
                ),
                const SizedBox(height: 12),
              ],
            if (_busy)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  children: [
                    const CircularProgressIndicator(),
                    if (questions != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Echo is writing your assistant…',
                        style: textTheme.bodySmall?.copyWith(color: palette.text2),
                      ),
                    ],
                  ],
                ),
              ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(error, style: textTheme.bodySmall?.copyWith(color: palette.red)),
              ),
            if (questions != null) ...[
              const SizedBox(height: 4),
              FilledButton.icon(
                key: const Key('wizard-create'),
                onPressed: _busy ? null : () => unawaited(_create()),
                icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                label: const Text('Write my assistant'),
              ),
            ],
            const SizedBox(height: 4),
            TextButton(
              key: const Key('wizard-skip'),
              onPressed: _busy ? null : () => unawaited(_openEditor()),
              child: const Text('Skip, I’ll write it myself'),
            ),
          ],
        ),
      ),
    );
  }
}

InputDecoration _fieldDecoration(EchoPalette palette, String hint) {
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide(color: palette.border),
  );
  return InputDecoration(
    hintText: hint,
    contentPadding: const EdgeInsets.all(14),
    border: border,
    enabledBorder: border,
    focusedBorder: border.copyWith(borderSide: BorderSide(color: palette.accent, width: 2)),
  );
}

/// One question: its options to tap (one, or several), and words for anything else.
final class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.number,
    required this.question,
    required this.picked,
    required this.words,
    required this.onTap,
    super.key,
  });

  final int number;
  final AssistantQuestion question;
  final Set<String> picked;
  final TextEditingController words;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(AppTheme.panelRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: palette.accentSoft, shape: BoxShape.circle),
                child: Text(
                  '$number',
                  style: textTheme.labelMedium?.copyWith(color: palette.onAccentSoft),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(question.text, style: textTheme.titleSmall)),
            ],
          ),
          if (question.multi)
            Padding(
              padding: const EdgeInsets.only(left: 34, top: 2),
              child: Text(
                'Choose any',
                style: textTheme.bodySmall?.copyWith(color: palette.text2),
              ),
            ),
          if (question.options.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in question.options)
                  FilterChip(
                    key: Key('wizard-option-${question.id}-$option'),
                    label: Text(option),
                    selected: picked.contains(option),
                    showCheckmark: question.multi,
                    onSelected: (_) => onTap(option),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            key: Key('wizard-words-${question.id}'),
            controller: words,
            minLines: 1,
            maxLines: 3,
            maxLength: 300,
            textCapitalization: TextCapitalization.sentences,
            decoration: _fieldDecoration(
              palette,
              question.hint.isNotEmpty
                  ? question.hint
                  : (question.options.isEmpty ? 'Your answer' : 'Something else'),
            ).copyWith(counterText: ''),
          ),
        ],
      ),
    );
  }
}
