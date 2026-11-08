import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/memory.dart';
import '../models/person.dart';
import '../models/segment.dart';
import '../models/task_item.dart';
import '../services/api/api_exception.dart';
import '../services/api/api_service.dart';
import '../services/app/spoken_language.dart';
import '../theme/app_theme.dart';
import '../widgets/conversation_card.dart';
import '../widgets/expandable_text.dart';
import '../utils/formatting.dart';
import '../widgets/memory_entity_row.dart';
import '../widgets/panel.dart';
import '../widgets/sections.dart';
import '../widgets/task_tile.dart';
import '../widgets/photo_thumbnail.dart';
import '../widgets/tip_card.dart';
import '../widgets/who_is_speaking_sheet.dart';
import '../utils/calendar_request.dart';
import 'navigation.dart';
import 'task_editing.dart';
import 'transcript_detail_screen.dart';
import '../services/app/sharing.dart';
import '../utils/conversation_text.dart';

enum _DetailTab { summary, transcript }

/// One conversation: what it was about (summary, tasks, events, people, ideas)
/// and what was said, line by line, each line correctable; lines heard in another
/// language are tagged and can be translated into the user's.
final class ConversationDetailScreen extends StatefulWidget {
  const ConversationDetailScreen({
    required this.conversationId,
    required this.api,
    this.onAsk,
    this.clock = DateTime.now,
    this.sharing = const SystemSharing(),
    this.spokenLanguage = _savedSpokenLanguage,
    super.key,
  });

  final String conversationId;
  final MemoryApi api;
  final Sharing sharing;
  final AskCallback? onAsk;
  final DateTime Function() clock;

  /// The language the user speaks ("it"); the phone's copy by default.
  final Future<String?> Function() spokenLanguage;

  static Future<String?> _savedSpokenLanguage() async =>
      (await SharedPreferences.getInstance()).getString(SpokenLanguageStore.key);

  @override
  State<ConversationDetailScreen> createState() => _ConversationDetailScreenState();
}

final class _ConversationDetailScreenState extends State<ConversationDetailScreen>
    with TaskEditing {
  @override
  MemoryApi get taskApi => widget.api;

  ConversationDetail? _detail;
  String? _error;
  bool _loading = true;
  bool _deleting = false;
  _DetailTab _tab = _DetailTab.summary;

  /// The user's language: lines heard in another one can be translated.
  String? _userLanguage;

  /// By segment id, once asked for; shown while [_showTranslation].
  Map<String, String>? _translations;
  bool _showTranslation = false;
  bool _translating = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_loadUserLanguage());
  }

  /// The phone's copy, else the account's (a phone that never opened Language).
  Future<void> _loadUserLanguage() async {
    String? language;
    try {
      language = await widget.spokenLanguage();
      final api = widget.api;
      if (language == null && api is AccountApi) language = (await (api as AccountApi).me()).language;
    } catch (_) {}
    if (mounted && language != null) setState(() => _userLanguage = language);
  }

  TranslateApi? get _translator {
    final api = widget.api;
    return api is TranslateApi ? api as TranslateApi : null;
  }

  bool _isForeign(TranscriptLine line) {
    final user = _userLanguage;
    return user != null && line.text != null && line.language != null && line.language != user;
  }

  /// Translate, or hide the translation; asks the server only for lines it has not got.
  Future<void> _toggleTranslation(List<TranscriptLine> foreign) async {
    final translator = _translator;
    if (translator == null || _translating) return;
    if (_showTranslation) {
      setState(() => _showTranslation = false);
      return;
    }
    final known = _translations;
    if (known != null && foreign.every((line) => known.containsKey(line.segmentId))) {
      setState(() => _showTranslation = true);
      return;
    }
    setState(() => _translating = true);
    try {
      final translation = await translator.translateConversation(widget.conversationId);
      if (!mounted) return;
      setState(() {
        _translations = translation.lines;
        _showTranslation = true;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not translate. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = _detail == null;
      _error = null;
    });
    try {
      final detail = await widget.api.getConversation(widget.conversationId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
        resetTaskEdits();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = userMessage(error, 'Could not load this conversation.');
      });
    }
  }

  /// Photos are shown only with an api that serves their images.
  PhotoSourceLoader? get _photoLoader {
    final api = widget.api;
    return api is PhotoApi ? (api as PhotoApi).photoImage : null;
  }

  VoiceApi? get _voices {
    final api = widget.api;
    return api is VoiceApi ? api as VoiceApi : null;
  }

  /// "Who is speaking?" for a line: Echo learns the voice and relabels the conversation.
  Future<void> _nameVoice(TranscriptLine line) async {
    final voices = _voices;
    if (voices == null) return;
    List<PersonSummary> people = const [];
    try {
      people = await widget.api.listPeople();
    } catch (_) {}
    if (!mounted) return;
    final choice = await showWhoIsSpeaking(context, people: people);
    if (choice == null || !mounted) return;
    await _voiceAction(() => voices.nameVoice(
          line.segmentId,
          isSelf: choice.isSelf,
          personId: choice.personId,
          name: choice.name,
        ));
  }

  Future<void> _voiceAction(Future<Object?> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final relabelled = await action();
      if (relabelled is int && relabelled > 0) {
        messenger.showSnackBar(SnackBar(
          content: Text(
            'Also recognised in $relabelled more line${relabelled == 1 ? '' : 's'}.',
          ),
        ));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(
        content: Text(userMessage(error, 'Could not save who is speaking.')),
      ));
    }
    await _load();
  }

  List<TaskItem> get _tasks {
    final detail = _detail;
    if (detail == null) return const [];
    return editedTasks(detail.ofType('task').map(TaskItem.fromEntity));
  }

  Future<void> _openLine(TranscriptLine line) async {
    final api = widget.api;
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TranscriptDetailScreen(
          segment: RecentSegment(
            id: line.segmentId,
            receivedAt: line.recordedAt,
            recordedAt: line.recordedAt,
            durationMs: 0,
            transcriptionStatus: line.status,
            text: line.text,
            speaker: line.speaker,
            conversationId: widget.conversationId,
          ),
          api: api is TranscriptMemoryApi ? api as TranscriptMemoryApi : null,
        ),
      ),
    );
    if (!mounted) return;
    if (deleted == true) {
      Navigator.of(context).pop();
      return;
    }
    // A corrected line is translated again when asked
    _translations?.remove(line.segmentId);
    await _load();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: const Text(
          'This permanently deletes the conversation, its transcript and what Echo '
          'learned from it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('conversation-delete-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: EchoPalette.of(context).red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await widget.api.deleteConversation(widget.conversationId);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _deleting = false);
      _showMessage(userMessage(error, 'Could not delete the conversation.'));
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      backgroundColor: EchoPalette.of(context).background,
      appBar: AppBar(
        actions: [
          if (detail != null)
            IconButton(
              key: const Key('conversation-share'),
              tooltip: 'Share conversation',
              icon: const Icon(Icons.ios_share_rounded),
              onPressed: () => unawaited(widget.sharing.shareText(
                conversationAsText(detail, widget.clock()),
                subject: detail.card.title ?? 'Conversation',
              )),
            ),
          if (detail != null)
            PopupMenuButton<String>(
              key: const Key('conversation-menu'),
              tooltip: 'More',
              enabled: !_deleting,
              onSelected: (_) => unawaited(_delete()),
              itemBuilder: (context) => [
                PopupMenuItem(
                  key: const Key('conversation-delete'),
                  value: 'delete',
                  child: Text(
                    'Delete conversation',
                    style: TextStyle(color: EchoPalette.of(context).red),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(key: Key('conversation-loading')));
    }
    final detail = _detail;
    if (detail == null) {
      return FullScreenMessage(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load this conversation',
        message: _error ?? '',
        actionKey: const Key('conversation-retry'),
        actionLabel: 'Retry',
        onAction: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('conversation-detail'),
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          _Header(card: detail.card, people: _people(detail), now: widget.clock()),
          if (widget.onAsk case final ask?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: OutlinedButton.icon(
                key: const Key('conversation-ask'),
                onPressed: () => askFromAnywhere(
                  context,
                  ask,
                  'What did we say in "${conversationTitle(detail.card)}" '
                  '(${dayLabel(detail.card.startedAt, widget.clock())}, '
                  '${formatTime(detail.card.startedAt)}), and what did I agree to do?',
                ),
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('Ask about this conversation'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SegmentedButton<_DetailTab>(
              key: const Key('conversation-tabs'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: _DetailTab.summary, label: Text('Summary')),
                ButtonSegment(value: _DetailTab.transcript, label: Text('Transcript')),
              ],
              selected: {_tab},
              onSelectionChanged: (selection) => setState(() => _tab = selection.single),
            ),
          ),
          if (_tab == _DetailTab.summary)
            ..._summary(detail)
          else
            ..._transcript(detail),
        ],
      ),
    );
  }

  List<String> _people(ConversationDetail detail) {
    final names = <String>[];
    for (final person in detail.ofType('person')) {
      if (!names.contains(person.name)) names.add(person.name);
    }
    return names;
  }

  List<Widget> _summary(ConversationDetail detail) {
    final card = detail.card;
    final textTheme = Theme.of(context).textTheme;
    final tasks = _tasks;
    final events = detail.ofType('event');
    final notes = [...detail.ofType('idea'), ...detail.ofType('note')];
    final now = widget.clock();
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Panel(
          child: Text(
          card.summary ??
              (card.isOpen
                  ? 'Echo is still listening. The summary is written a few minutes after '
                      'the conversation ends.'
                  : card.isProcessing
                      ? 'Echo is still processing this conversation.'
                      : 'Too short for a summary. The transcript has everything that was said.'),
          key: const Key('conversation-summary'),
          style: card.summary == null
              ? textTheme.bodyMedium?.copyWith(color: EchoPalette.of(context).text2)
              : textTheme.bodyLarge?.copyWith(height: 1.5),
          ),
        ),
      ),
      if (detail.photos.isNotEmpty && _photoLoader != null)
        PanelSection(title: 'Photos', children: [
          for (final photo in detail.photos)
            _PhotoTile(photo: photo, loadSource: _photoLoader!),
        ]),
      if (tasks.isNotEmpty)
        PanelSection(title: 'Tasks', children: [
          for (final task in tasks)
            TaskTile(
              task: task,
              busy: isTaskBusy(task),
              now: now,
              padding: const EdgeInsets.only(left: 6, right: 4),
              onToggle: () => unawaited(toggleTask(task)),
              onDismiss: () => unawaited(dismissTask(task)),
            ),
        ]),
      if (events.isNotEmpty)
        PanelSection(title: 'Events', children: [
          for (final event in events)
            MemoryEntityRow(
              entity: event,
              now: now,
              onAddToCalendar: widget.onAsk == null
                  ? null
                  : () => askFromAnywhere(context, widget.onAsk!, calendarRequest(event)),
            ),
        ]),
      if (notes.isNotEmpty)
        PanelSection(title: 'Ideas & notes', children: [
          for (final note in notes) MemoryEntityRow(entity: note, now: now),
        ]),
    ];
  }

  List<Widget> _transcript(ConversationDetail detail) {
    if (detail.lines.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: SectionEmpty(message: 'No transcript yet.'),
        ),
      ];
    }
    final loader = _photoLoader;
    final voices = _voices;
    // Each photo where it was taken, between the lines
    final photos = loader == null ? const <ConversationPhoto>[] : detail.photos;
    var next = 0;
    final foreign = detail.lines.where(_isForeign).toList();
    final user = _userLanguage;
    return [
      if (foreign.isNotEmpty && _translator != null && user != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 20, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('transcript-translate'),
              onPressed: _translating ? null : () => unawaited(_toggleTranslation(foreign)),
              icon: _translating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.translate_rounded, size: 18),
              label: Text(
                _translating
                    ? 'Translating…'
                    : _showTranslation
                        ? 'Hide translation'
                        : 'Translate to ${spokenLanguages[user] ?? user}',
              ),
            ),
          ),
        ),
      if (voices != null)
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: TipCard(
            tipKey: 'name_speakers',
            text: 'Tap a speaker to tell Echo who it is: Echo then recognises that voice '
                'in other conversations too.',
          ),
        ),
      for (final line in detail.lines) ...[
        for (; next < photos.length && !photos[next].takenAt.isAfter(line.recordedAt); next++)
          _PhotoTile(photo: photos[next], loadSource: loader!, compact: true),
        _LineTile(
          line: line,
          languageTag: _isForeign(line) ? line.language!.toUpperCase() : null,
          translation: _showTranslation ? (_translations ?? const {})[line.segmentId] : null,
          onTap: line.text == null ? null : () => unawaited(_openLine(line)),
          // Several voices: naming the segment's voice would name a mix of them
          onSpeakerTap: _voices == null || line.text == null || line.turns.isNotEmpty
              ? null
              : () => unawaited(_nameVoice(line)),
          onConfirmVoice: _voices == null || !line.isSuggestion || line.turns.isNotEmpty
              ? null
              : () => unawaited(_voiceAction(
                    () => _voices!.nameVoice(line.segmentId, name: line.speakerName),
                  )),
          onRejectVoice: _voices == null || !line.isSuggestion || line.turns.isNotEmpty
              ? null
              : () => unawaited(_voiceAction(() async {
                    await _voices!.rejectVoice(line.segmentId);
                    return null;
                  })),
        ),
      ],
      for (final photo in photos.skip(next))
        _PhotoTile(photo: photo, loadSource: loader!, compact: true),
    ];
  }
}

final class _Header extends StatelessWidget {
  const _Header({required this.card, required this.people, required this.now});

  final ConversationCard card;
  final List<String> people;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final end = card.endedAt;
    final range = end == null || card.duration.inSeconds < 60
        ? formatTime(card.startedAt)
        : '${formatTime(card.startedAt)}–${formatTime(end)} · ${formatDuration(card.duration)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConversationEmoji(emoji: card.emoji, size: 52),
          const SizedBox(height: 12),
          Semantics(
            header: true,
            child: Text(conversationTitle(card), style: textTheme.displayLarge?.copyWith(fontSize: 28)),
          ),
          const SizedBox(height: 4),
          Text(
            '${dayLabel(card.startedAt, now)} · $range',
            style: textTheme.bodySmall,
          ),
          if (card.place case final place? when place.label != null) ...[
            const SizedBox(height: 6),
            Row(
              key: const Key('conversation-place'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.place_outlined, size: 16, color: palette.text2),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    [
                      place.label!,
                      if (place.name != null && place.address != null) place.address!,
                    ].join(' · '),
                    style: textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
          if (card.isOpen) ...[
            const SizedBox(height: 4),
            Text(
              'Live · still listening',
              style: textTheme.bodySmall?.copyWith(
                color: palette.liveText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (people.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final name in people)
                  Chip(
                    avatar: Icon(Icons.person_outline_rounded, size: 16, color: palette.text2),
                    label: Text(name),
                    visualDensity: VisualDensity.compact,
                    side: BorderSide.none,
                    shape: const StadiumBorder(),
                    backgroundColor: palette.surface,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

final class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.line,
    required this.onTap,
    this.languageTag,
    this.translation,
    this.onSpeakerTap,
    this.onConfirmVoice,
    this.onRejectVoice,
  });

  final TranscriptLine line;
  final VoidCallback? onTap;

  /// "EN" for a line heard in another language than the user's.
  final String? languageTag;

  /// The line in the user's language, shown under it.
  final String? translation;

  /// "Who is speaking?"
  final VoidCallback? onSpeakerTap;

  /// For a suggested voice ("Marco?"): yes, or no.
  final VoidCallback? onConfirmVoice;
  final VoidCallback? onRejectVoice;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final text = line.text;
    final turns = line.turns;
    final speaker = turns.isEmpty ? line.speakerLabel : turns.first.speakerLabel;
    final body = turns.isNotEmpty
        // Read aloud after the first speaker's name (the label below says it)
        ? [for (final (i, t) in turns.indexed) i == 0 ? t.text : '${t.speakerLabel}: ${t.text}']
            .join('. ')
        : text != null
            ? cleanTranscript(text)
            : line.isFailed
                ? 'Transcription failed'
                : 'Transcribing…';
    Color speakerColor(String? who, String? name) => who == 'self'
        ? palette.accent
        : name != null
            ? palette.green
            : palette.text2;
    return Semantics(
      button: onTap != null,
      label: '${formatTime(line.recordedAt)}, $speaker: '
          '${languageTag == null ? '' : 'In $languageTag: '}$body'
          '${translation == null ? '' : '. Translation: $translation'}',
      excludeSemantics: true,
      child: InkWell(
        key: Key('line-${line.segmentId}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 52,
                child: Text(
                  formatTime(line.recordedAt),
                  style: textTheme.bodySmall?.copyWith(fontSize: 12),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Semantics(
                          button: onSpeakerTap != null,
                          label: 'Who is speaking: $speaker',
                          child: InkWell(
                            key: Key('speaker-${line.segmentId}'),
                            onTap: onSpeakerTap,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                speaker,
                                style: textTheme.labelSmall?.copyWith(
                                  fontSize: 12,
                                  color: turns.isEmpty
                                      ? speakerColor(line.speaker, line.speakerName)
                                      : speakerColor(turns.first.speaker, turns.first.speakerName),
                                  decoration: onSpeakerTap == null
                                      ? null
                                      : TextDecoration.underline,
                                  decorationStyle: TextDecorationStyle.dotted,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (languageTag != null)
                          Padding(
                            key: Key('lang-${line.segmentId}'),
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              languageTag!,
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 11,
                                color: palette.text2,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                        if (onConfirmVoice != null)
                          _VoiceButton(
                            key: Key('voice-yes-${line.segmentId}'),
                            icon: Icons.check_rounded,
                            tooltip: 'Yes, it is ${line.speakerName}',
                            color: palette.green,
                            onPressed: onConfirmVoice!,
                          ),
                        if (onRejectVoice != null)
                          _VoiceButton(
                            key: Key('voice-no-${line.segmentId}'),
                            icon: Icons.close_rounded,
                            tooltip: 'No, not ${line.speakerName}',
                            color: palette.text2,
                            onPressed: onRejectVoice!,
                          ),
                      ],
                    ),
                    if (turns.isNotEmpty)
                      for (final (i, turn) in turns.indexed) ...[
                        if (i > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              turn.speakerLabel,
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 12,
                                color: speakerColor(turn.speaker, turn.speakerName),
                              ),
                            ),
                          ),
                        Text(turn.text, style: textTheme.bodyMedium),
                      ]
                    else
                    Text(
                      body,
                      style: text == null
                          ? textTheme.bodyMedium?.copyWith(
                              color: line.isFailed ? palette.red : palette.text2,
                              fontStyle: FontStyle.italic,
                            )
                          : textTheme.bodyMedium,
                    ),
                    if (translation != null)
                      Padding(
                        key: Key('translation-${line.segmentId}'),
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          translation!,
                          style: textTheme.bodyMedium?.copyWith(
                            color: palette.text2,
                            fontStyle: FontStyle.italic,
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

final class _VoiceButton extends StatelessWidget {
  const _VoiceButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 18, color: color),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 32),
      padding: EdgeInsets.zero,
    );
  }
}

/// A photo of the conversation and what Echo said about it.
final class _PhotoTile extends StatelessWidget {
  const _PhotoTile({required this.photo, required this.loadSource, this.compact = false});

  final ConversationPhoto photo;
  final PhotoSourceLoader loadSource;

  /// In the transcript: the time on the left, a smaller picture.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PhotoThumbnail(
          photoId: photo.id,
          loadSource: loadSource,
          height: compact ? 160 : 200,
        ),
        if (photo.answer != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ExpandableText(
              photo.answer!,
              maxLines: compact ? 2 : 4,
              style: textTheme.bodySmall,
            ),
          ),
      ],
    );
    return Padding(
      key: Key('conversation-photo-${photo.id}'),
      padding: EdgeInsets.fromLTRB(20, compact ? 4 : 8, 20, 8),
      child: compact
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 52,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      formatTime(photo.takenAt),
                      style: textTheme.bodySmall?.copyWith(fontSize: 12),
                    ),
                  ),
                ),
                Expanded(child: body),
              ],
            )
          : body,
    );
  }
}
