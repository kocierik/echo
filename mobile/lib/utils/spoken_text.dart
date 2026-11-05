import 'answer_blocks.dart';

final _link = RegExp(r'\[([^\]]*)\]\([^)]*\)');
final _bareLink = RegExp(r'https?://(?:www\.)?([^/\s?#]+)\S*');
final _marker = RegExp(r'^\s*(#{1,6}|[-*+•>]|\d+[.)])\s+');
final _marks = RegExp(r'\*\*|__|`|\*');
final _italic = RegExp(r'(?<!\w)_(\S(?:.*?\S)?)_(?!\w)');
final _emoji = RegExp(r'[\p{Extended_Pictographic}\u{FE0F}\u{200D}]', unicode: true);
final _tableRule = RegExp(r'^\|[\s:|-]+\|?$');
final _sentenceEnd = RegExp(r'[.!?:;…]$');

/// An answer as the phone reads it aloud: no markdown marks, emoji or link addresses (a
/// bare link says its site), table rows as lists, each line ending as a sentence so the
/// voice pauses. Past [limit] characters it stops at a sentence end in its second half
/// (else at a word) and says the rest is in Ask, in [language] ("it" or "en").
String spokenText(String markdown, {required String language, int limit = 500}) {
  final lines = <String>[];
  // A chart is for the screen: its numbers are in the words around it
  for (final raw in withoutCharts(markdown).split('\n')) {
    var line = raw.trim();
    if (line.startsWith('|')) {
      if (_tableRule.hasMatch(line)) continue;
      line = line.split('|').map((cell) => cell.trim()).where((c) => c.isNotEmpty).join(', ');
    }
    line = line
        .replaceAllMapped(_link, (m) => m[1]!)
        .replaceAllMapped(_bareLink, (m) => m[1]!)
        .replaceFirst(_marker, '')
        .replaceAll(_marks, '')
        .replaceAllMapped(_italic, (m) => m[1]!)
        .replaceAll(_emoji, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (line.isEmpty) continue;
    lines.add(_sentenceEnd.hasMatch(line) ? line : '$line.');
  }
  final text = lines.join('\n');
  if (text.length <= limit) return text;

  final tail = language == 'it' ? 'Il resto è in Ask.' : 'The rest is in Ask.';
  final window = text.substring(0, limit);
  final ends = RegExp(r'[.!?](?=\s|$)')
      .allMatches(window)
      .where((end) => end.end > limit ~/ 2);
  if (ends.isNotEmpty) return '${window.substring(0, ends.last.end)} $tail';
  final word = window.lastIndexOf(RegExp(r'\s'));
  final cut = (word > 0 ? window.substring(0, word) : window).trimRight();
  return '$cut… $tail';
}
