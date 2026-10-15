import '../models/memory.dart';
import 'formatting.dart';

/// A conversation as plain text (Markdown-flavoured) for sharing: title, time,
/// summary, what was extracted, and the transcript with who said what.
String conversationAsText(ConversationDetail detail, DateTime now) {
  final card = detail.card;
  final buffer = StringBuffer()..writeln('# ${card.title ?? 'Conversation'}');
  final end = card.endedAt;
  buffer.writeln(
    '${dayLabel(card.startedAt, now)} · ${formatTime(card.startedAt)}'
    '${end == null ? '' : '–${formatTime(end)}'}',
  );
  if (card.summary != null) buffer..writeln()..writeln(card.summary);

  void section(String title, String type) {
    final items = detail.ofType(type);
    if (items.isEmpty) return;
    buffer..writeln()..writeln('## $title');
    for (final item in items) {
      buffer.writeln('- ${item.name}${item.content == null ? '' : ': ${item.content}'}');
    }
  }

  section('Tasks', 'task');
  section('Events', 'event');
  section('People', 'person');
  section('Ideas', 'idea');

  final lines = detail.lines.where((line) => line.text != null).toList();
  if (lines.isNotEmpty) {
    buffer..writeln()..writeln('## Transcript');
    for (final line in lines) {
      buffer.writeln(
        '${formatTime(line.recordedAt)} ${line.speakerLabel}: ${cleanTranscript(line.text!)}',
      );
    }
  }
  return buffer.toString().trimRight();
}
