import '../widgets/echo_chart.dart';

/// A piece of an answer: Markdown, a chart, or a chart still being written.
sealed class AnswerBlock {
  const AnswerBlock();
}

final class TextBlock extends AnswerBlock {
  const TextBlock(this.markdown);

  final String markdown;
}

final class ChartBlock extends AnswerBlock {
  const ChartBlock(this.spec);

  final ChartSpec spec;
}

/// A ```echo-chart block not closed yet: the answer is still coming.
final class PendingChartBlock extends AnswerBlock {
  const PendingChartBlock();
}

const _fence = '```echo-chart';
final _closed = RegExp(r'```echo-chart[^\n]*\n([\s\S]*?)\n?```');

/// [answer] split at its chart blocks (backend/app/services/visuals.py). A block that is
/// not a chart Echo can draw is left out, never shown as code.
List<AnswerBlock> answerBlocks(String answer) {
  if (!answer.contains(_fence)) return [TextBlock(answer)];
  final blocks = <AnswerBlock>[];
  var at = 0;
  void text(String markdown) {
    if (markdown.trim().isNotEmpty) blocks.add(TextBlock(markdown.trim()));
  }

  for (final match in _closed.allMatches(answer)) {
    text(answer.substring(at, match.start));
    if (ChartSpec.tryParse(match[1]!) case final spec?) blocks.add(ChartBlock(spec));
    at = match.end;
  }
  final rest = answer.substring(at);
  final open = rest.indexOf(_fence);
  if (open >= 0) {
    text(rest.substring(0, open));
    blocks.add(const PendingChartBlock());
  } else {
    text(rest);
  }
  return blocks;
}

/// The answer without its chart blocks: for reading it aloud, copying, notifications.
String withoutCharts(String answer) =>
    answerBlocks(answer).whereType<TextBlock>().map((block) => block.markdown).join('\n\n');
