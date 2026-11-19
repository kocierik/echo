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
        // Two points say nothing a sentence does not
        '{"type": "line", "labels": ["a", "b"], "values": [285, 287]}',
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
      await _pump(
          tester,
          EchoChart(ChartSpec.tryParse(
            '{"type": "pie", "labels": ["Lavoro", "Casa"], "values": [3, 1]}',
          )!));

      expect(find.text('75%'), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);
    });

    testWidgets('a line and a progress bar draw', (tester) async {
      await _pump(
          tester,
          Column(children: [
            EchoChart(ChartSpec.tryParse(
              '{"type": "line", "unit": "h", "labels": ["lun", "mar", "mer", "gio", "ven"], '
              '"values": [7, 6.5, 8, 5, 7.5]}',
            )!),
            EchoChart(ChartSpec.tryParse(
              '{"type": "progress", "title": "Budget", "unit": "€", "value": 760, "max": 700}',
            )!),
          ]));

      expect(find.text('lun'), findsOneWidget);
      expect(find.textContaining('of 700 €'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('richer', () {
    testWidgets('columns with their values, the target dashed and the note', (tester) async {
      final spec = ChartSpec.tryParse(
        '{"type": "column", "title": "Sonno", "unit": "h", "labels": ["lun", "mar", "mer", "gio"], '
        '"values": [6.9, 6.4, 8.5, 5.7], "target": 8, "note": "Giovedì la notte più corta"}',
      )!;
      await _pump(tester, EchoChart(spec));

      expect(spec.kind, ChartKind.column);
      expect(spec.target, 8);
      expect(find.text('gio'), findsOneWidget);
      expect(find.text('Target 8 h'), findsOneWidget);
      expect(find.text('Giovedì la notte più corta'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('at most 14 columns; a pie has no target', () {
      final columns = ChartSpec.tryParse(
        '{"type": "column", "labels": ${List.generate(20, (i) => '"$i"')}, '
        '"values": ${List.generate(20, (i) => i)}}',
      )!;
      final pie = ChartSpec.tryParse(
        '{"type": "pie", "labels": ["a", "b"], "values": [1, 2], "target": 3}',
      )!;

      expect(columns.labels, hasLength(ChartSpec.maxColumns));
      expect(pie.target, isNull);
    });

    test('over the target a bar is amber, the largest full, the others softer', () {
      const palette = EchoPalette.light;

      expect(barColor(palette, 9, 8, emphasized: false), palette.amber);
      expect(barColor(palette, 7, 8, emphasized: true), palette.accent);
      expect(barColor(palette, 7, 8, emphasized: false), isNot(palette.accent));
      expect(barColor(palette, -1, null, emphasized: true), palette.red);
    });

    test('a line follows its values, from zero when they are near it', () {
      final (priceLow, priceHigh) = lineRange([285, 290, 287, 295]);
      final (sleepLow, _) = lineRange([6.9, 6.4, 7.5, 5.7]);
      final (kmLow, _) = lineRange([1.2, 3.5, 0.8, 4.1]);

      expect(priceLow, greaterThan(270));
      expect(priceHigh, greaterThan(295));
      // The differences show: not from zero
      expect(sleepLow, closeTo(5.43, 0.01));
      expect(kmLow, 0);
    });
  });

  test('chart colours read on the panel (3:1) and none is orange', () {
    double ratio(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
    }

    for (final theme in [AppTheme.dark, AppTheme.light]) {
      final palette = theme.extension<EchoPalette>()!;
      for (final color in chartColors(palette)) {
        expect(ratio(color, palette.surface), greaterThanOrEqualTo(3));
        final hsl = HSLColor.fromColor(color);
        final orange = color != palette.amber && hsl.saturation > 0.2 && hsl.hue >= 15 && hsl.hue <= 45;
        expect(orange, isFalse);
      }
    }
  });
}
