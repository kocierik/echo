import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/utils/answer_blocks.dart';
import 'package:echo_app/utils/spoken_text.dart';
import 'package:echo_app/widgets/echo_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _answer = '''Ad ottobre hai speso **640 €**.

```echo-chart
{"type": "bar", "title": "Spese di ottobre", "unit": "€", "labels": ["Spesa", "Casa", "Svago"], "values": [280, 160, 120]}
```

La spesa è la voce più grande.''';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ));

void main() {
  group('answer blocks', () {
    test('the text around a chart, and the chart', () {
      final blocks = answerBlocks(_answer);

      expect(blocks, hasLength(3));
      expect((blocks[0] as TextBlock).markdown, 'Ad ottobre hai speso **640 €**.');
      final spec = (blocks[1] as ChartBlock).spec;
      expect(spec.kind, ChartKind.bar);
      expect(spec.labels, ['Spesa', 'Casa', 'Svago']);
      expect(spec.series.single.values, [280.0, 160.0, 120.0]);
      expect((blocks[2] as TextBlock).markdown, 'La spesa è la voce più grande.');
    });

    test('a chart still being written waits, and is never shown as code', () {
      final blocks = answerBlocks('Ecco:\n```echo-chart\n{"type": "bar", "labe');

      expect(blocks.last, isA<PendingChartBlock>());
      expect((blocks.first as TextBlock).markdown, 'Ecco:');
    });

    test('a block that is not a chart is left out', () {
      final blocks = answerBlocks('Prima\n```echo-chart\nnot json\n```\nDopo');

      expect(blocks.map((b) => (b as TextBlock).markdown), ['Prima', 'Dopo']);
    });

    test('an answer without charts is one block, as written', () {
      expect((answerBlocks('Ciao **Erik**').single as TextBlock).markdown, 'Ciao **Erik**');
    });

    test('read aloud without the chart', () {
      final spoken = spokenText(_answer, language: 'it');

      expect(spoken, contains('640 €'));
      expect(spoken, isNot(contains('labels')));
    });
  });

  group('chart spec', () {
    test('values are cut to the labels and to what fits', () {
      final spec = ChartSpec.tryParse(
        '{"type": "bar", "labels": ${List.generate(20, (i) => '"$i"')}, '
        '"values": ${List.generate(20, (i) => i)}}',
      )!;

      expect(spec.labels, hasLength(ChartSpec.maxBars));
      expect(spec.series.single.values, hasLength(ChartSpec.maxBars));
    });

    test('several lines, a progress bar, and what is refused', () {
      final line = ChartSpec.tryParse(
        '{"type": "line", "labels": ["lun", "mar", "mer"], "series": '
        '[{"name": "Io", "values": [7, 6.5, 8]}, {"name": "Obiettivo", "values": [8, 8, 8]}]}',
      )!;
      expect(line.series.map((s) => s.name), ['Io', 'Obiettivo']);

      final progress =
          ChartSpec.tryParse('{"type": "progress", "unit": "€", "value": 640, "max": 700}')!;
      expect(progress.format(progress.value), '640 €');

      for (final bad in [
        '{"type": "radar", "labels": ["a"], "values": [1]}',
        '{"type": "bar", "labels": ["a"], "values": ["x"]}',
        '{"type": "pie", "labels": ["a", "b"], "values": [3, -1]}',
        '{"type": "line", "labels": ["a"], "values": [1]}',
        '{"type": "progress", "value": 1, "max": 0}',
        '[1, 2]',
      ]) {
        expect(ChartSpec.tryParse(bad), isNull, reason: bad);
      }
    });

    test('numbers read as people write them', () {
      const hours = ChartSpec(kind: ChartKind.bar, unit: 'h');
      const share = ChartSpec(kind: ChartKind.bar, unit: '%');

      expect(hours.format(7.5), '7.5 h');
      expect(share.format(30), '30%');
      expect(const ChartSpec(kind: ChartKind.bar).format(1200), '1200');
    });
  });

  group('drawn', () {
    testWidgets('bars with their labels and values', (tester) async {
      await _pump(tester, EchoChart((answerBlocks(_answer)[1] as ChartBlock).spec));

      expect(find.text('Spese di ottobre'), findsOneWidget);
      expect(find.text('Casa'), findsOneWidget);
      expect(find.text('160 €'), findsOneWidget);
    });

    testWidgets('a pie says each share', (tester) async {
      await _pump(tester, EchoChart(ChartSpec.tryParse(
        '{"type": "pie", "labels": ["Lavoro", "Casa"], "values": [3, 1]}',
      )!));

      expect(find.text('75%'), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);
    });

    testWidgets('a line and a progress bar draw', (tester) async {
      await _pump(tester, Column(children: [
        EchoChart(ChartSpec.tryParse(
          '{"type": "line", "unit": "h", "labels": ["lun", "mar", "mer", "gio", "ven"], '
          '"values": [7, 6.5, 8, 5, 7.5]}',
        )!),
        EchoChart(ChartSpec.tryParse(
          '{"type": "progress", "title": "Budget", "unit": "€", "value": 760, "max": 700}',
        )!),
      ]));

      expect(find.text('lun'), findsOneWidget);
      expect(find.text('8 h'), findsOneWidget);
      expect(find.textContaining('of 700 €'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
