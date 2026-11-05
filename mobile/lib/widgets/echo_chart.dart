import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The kinds of chart an answer can carry (backend/app/services/visuals.py).
enum ChartKind { bar, line, pie, progress }

@immutable
final class ChartSeries {
  const ChartSeries(this.name, this.values);

  final String name;
  final List<double> values;
}

/// A chart from an answer's ```echo-chart block: what the model wrote, checked and cut to
/// what fits on a phone. [tryParse] is null for anything else, and the block is left out.
@immutable
final class ChartSpec {
  const ChartSpec({
    required this.kind,
    this.title = '',
    this.unit = '',
    this.labels = const [],
    this.series = const [],
    this.value = 0,
    this.max = 0,
  });

  static const maxBars = 12;
  static const maxSlices = 8;
  static const maxPoints = 31;
  static const maxLines = 3;

  final ChartKind kind;
  final String title;
  final String unit;
  final List<String> labels;
  final List<ChartSeries> series;

  /// A progress bar's value and target.
  final double value;
  final double max;

  static ChartSpec? tryParse(String source) {
    try {
      final data = jsonDecode(source);
      if (data is! Map<String, dynamic>) return null;
      final kind = ChartKind.values.where((k) => k.name == data['type']).firstOrNull;
      if (kind == null) return null;
      final title = _text(data['title'], 80);
      final unit = _text(data['unit'], 12);
      if (kind == ChartKind.progress) {
        final value = _number(data['value']);
        final max = _number(data['max']);
        if (value == null || max == null || max <= 0) return null;
        return ChartSpec(kind: kind, title: title, unit: unit, value: value, max: max);
      }
      final labels = [
        for (final label in data['labels'] as List<dynamic>? ?? const []) _text(label, 30),
      ];
      final most = switch (kind) {
        ChartKind.bar => maxBars,
        ChartKind.pie => maxSlices,
        _ => maxPoints,
      };
      final raw = data['series'] is List
          ? [
              for (final item in data['series'] as List<dynamic>)
                if (item is Map<String, dynamic>) (_text(item['name'], 30), item['values']),
            ].take(kind == ChartKind.line ? maxLines : 1)
          : [('', data['values'])];
      final series = <ChartSeries>[];
      for (final (name, values) in raw) {
        if (values is! List) continue;
        final numbers = [for (final v in values) _number(v)];
        if (numbers.contains(null)) continue;
        series.add(ChartSeries(name, numbers.cast<double>()));
      }
      if (series.isEmpty) return null;
      // As many points as labels, and no more than fit
      final count = [labels.length, most, ...series.map((s) => s.values.length)].reduce(math.min);
      final minimum = kind == ChartKind.line ? 2 : 1;
      if (count < minimum) return null;
      final cut = [
        for (final s in series) ChartSeries(s.name, s.values.take(count).toList()),
      ];
      if (kind == ChartKind.pie && cut.first.values.any((v) => v < 0)) return null;
      return ChartSpec(
        kind: kind,
        title: title,
        unit: unit,
        labels: labels.take(count).toList(),
        series: cut,
      );
    } catch (_) {
      return null;
    }
  }

  static String _text(Object? value, int most) {
    final text = (value is String ? value : value?.toString() ?? '').trim();
    return text.length > most ? '${text.substring(0, most - 1)}…' : text;
  }

  static double? _number(Object? value) {
    final number = value is num ? value.toDouble() : double.tryParse('$value');
    return number != null && number.isFinite ? number : null;
  }

  /// "280 €", "7.5 h", "30%".
  String format(double number) {
    final digits = number == number.roundToDouble()
        ? number.toStringAsFixed(0)
        : number.abs() < 10
            ? number.toStringAsFixed(1)
            : number.toStringAsFixed(0);
    if (unit.isEmpty) return digits;
    return unit == '%' ? '$digits%' : '$digits $unit';
  }
}

/// Distinct, calm colors that read on both themes; the first is Echo's accent.
List<Color> chartColors(EchoPalette palette) => [
      palette.accent,
      palette.amber,
      const Color(0xFF7C6FD6),
      const Color(0xFFE07A5F),
      const Color(0xFF4A90C2),
      palette.green,
      const Color(0xFFC46BA8),
      const Color(0xFF9AA04A),
    ];

/// An answer's chart, in a panel of its own.
final class EchoChart extends StatelessWidget {
  const EchoChart(this.spec, {super.key});

  final ChartSpec spec;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Container(
      key: const Key('echo-chart'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: palette.surface2,
        borderRadius: BorderRadius.circular(AppTheme.tileRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (spec.title.isNotEmpty) ...[
            Text(spec.title, style: textTheme.titleSmall),
            const SizedBox(height: 10),
          ],
          switch (spec.kind) {
            ChartKind.bar => _Bars(spec),
            ChartKind.pie => _Pie(spec),
            ChartKind.line => _Line(spec),
            ChartKind.progress => _Progress(spec),
          },
        ],
      ),
    );
  }
}

/// Bars across: a phone has more width for a label than height for many columns.
final class _Bars extends StatelessWidget {
  const _Bars(this.spec);

  final ChartSpec spec;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final values = spec.series.first.values;
    final top = values.map((v) => v.abs()).fold<double>(0, math.max);
    return Column(
      children: [
        for (final (index, value) in values.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 92,
                  child: Text(
                    spec.labels[index],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(color: palette.text2),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 14,
                        width: top == 0 ? 2 : math.max(2, constraints.maxWidth * value.abs() / top),
                        decoration: BoxDecoration(
                          color: value < 0 ? palette.red : palette.accent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  spec.format(value),
                  style: textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

final class _Pie extends StatelessWidget {
  const _Pie(this.spec);

  final ChartSpec spec;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final values = spec.series.first.values;
    final total = values.fold<double>(0, (a, b) => a + b);
    final colors = chartColors(palette);
    return Row(
      children: [
        SizedBox.square(
          dimension: 110,
          child: CustomPaint(
            painter: _PiePainter(values, colors, palette.surface2),
            child: Center(
              child: Text(
                spec.format(total),
                style: textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (index, value) in values.indexed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: colors[index % colors.length],
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          spec.labels[index],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall,
                        ),
                      ),
                      Text(
                        total == 0 ? spec.format(value) : '${(100 * value / total).round()}%',
                        style: textTheme.bodySmall?.copyWith(color: palette.text2),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

final class _PiePainter extends CustomPainter {
  _PiePainter(this.values, this.colors, this.gap);

  final List<double> values;
  final List<Color> colors;
  final Color gap;

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<double>(0, (a, b) => a + b);
    final stroke = size.shortestSide * 0.18;
    final rect = Offset(stroke / 2, stroke / 2) & Size(size.width - stroke, size.height - stroke);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    if (total <= 0) {
      canvas.drawArc(
          rect, 0, 2 * math.pi, false, paint..color = colors.first.withValues(alpha: 0.3));
      return;
    }
    var start = -math.pi / 2;
    for (final (index, value) in values.indexed) {
      final sweep = 2 * math.pi * value / total;
      canvas.drawArc(rect, start, sweep, false, paint..color = colors[index % colors.length]);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_PiePainter old) => old.values != values || old.colors != colors;
}

final class _Line extends StatelessWidget {
  const _Line(this.spec);

  final ChartSpec spec;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final colors = chartColors(palette);
    final all = [for (final s in spec.series) ...s.values];
    final low = math.min(0.0, all.reduce(math.min));
    final high = all.reduce(math.max);
    final labelStyle = textTheme.labelSmall?.copyWith(color: palette.text2);
    final last = spec.labels.length - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (spec.series.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                for (final (index, s) in spec.series.indexed)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 12, height: 3, color: colors[index % colors.length]),
                      const SizedBox(width: 6),
                      Text(s.name, style: textTheme.bodySmall),
                    ],
                  ),
              ],
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 140,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(spec.format(high), style: labelStyle),
                  Text(spec.format(low), style: labelStyle),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 140,
                child: CustomPaint(
                  painter: _LinePainter(
                    spec.series,
                    low,
                    high,
                    colors,
                    palette.border,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: 40),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(spec.labels.first, style: labelStyle),
              if (last >= 4) Text(spec.labels[last ~/ 2], style: labelStyle),
              Text(spec.labels[last], style: labelStyle),
            ],
          ),
        ),
      ],
    );
  }
}

final class _LinePainter extends CustomPainter {
  _LinePainter(this.series, this.low, this.high, this.colors, this.grid);

  final List<ChartSeries> series;
  final double low;
  final double high;
  final List<Color> colors;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    final span = high - low == 0 ? 1 : high - low;
    for (final (index, s) in series.indexed) {
      final color = colors[index % colors.length];
      final step = s.values.length > 1 ? size.width / (s.values.length - 1) : 0.0;
      final points = [
        for (final (i, v) in s.values.indexed)
          Offset(i * step, size.height - size.height * (v - low) / span),
      ];
      final path = Path()..addPolygon(points, false);
      if (series.length == 1) {
        // The area under a single line, faint
        final area = Path.from(path)
          ..lineTo(points.last.dx, size.height)
          ..lineTo(points.first.dx, size.height)
          ..close();
        canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.12));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
      // The last point stands out: where things are now
      canvas.drawCircle(points.last, 4, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.series != series || old.colors != colors;
}

final class _Progress extends StatelessWidget {
  const _Progress(this.spec);

  final ChartSpec spec;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final share = spec.value / spec.max;
    final over = share > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(children: [
            TextSpan(
              text: spec.format(spec.value),
              style: textTheme.titleMedium?.copyWith(
                color: over ? palette.red : palette.text,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: '  of ${spec.format(spec.max)} · ${(100 * share).round()}%',
              style: textTheme.bodySmall?.copyWith(color: palette.text2),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: share.clamp(0, 1).toDouble(),
            minHeight: 12,
            color: over ? palette.red : palette.accent,
            backgroundColor: palette.border,
          ),
        ),
      ],
    );
  }
}
