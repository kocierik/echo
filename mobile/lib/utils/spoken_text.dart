/// An answer as the phone reads it aloud: no markdown marks or links, one line per line
/// of the answer; past [limit] characters it stops at a sentence end (else at a word)
/// and says the rest is in Ask, in [language] ("it" or "en").
String spokenText(String markdown, {required String language, int limit = 500}) {
  final lines = <String>[];
  for (final raw in markdown.split('\n')) {
    final line = raw
        .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
        .replaceAll(RegExp(r'https?://\S+'), '')
        .replaceFirst(RegExp(r'^\s*(#{1,6}|[-*+•>]|\d+[.)])\s+'), '')
        .replaceAll(RegExp(r'\*\*|__|`|\*'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (line.isNotEmpty) lines.add(line);
  }
  final text = lines.join('\n');
  if (text.length <= limit) return text;

  final tail = language == 'it' ? 'Il resto è in Ask.' : 'The rest is in Ask.';
  final window = text.substring(0, limit);
  final ends = RegExp(r'[.!?](?=\s|$)').allMatches(window);
  if (ends.isNotEmpty) return '${window.substring(0, ends.last.end)} $tail';
  final word = window.lastIndexOf(RegExp(r'\s'));
  final cut = (word > 0 ? window.substring(0, word) : window).trimRight();
  return '$cut… $tail';
}
