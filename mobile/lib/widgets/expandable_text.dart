import 'package:flutter/material.dart';

/// A text in at most [maxLines] that opens in full on a tap when it does not fit, and
/// closes on another: no text in the app is cut without a way to read all of it.
final class ExpandableText extends StatefulWidget {
  const ExpandableText(this.text, {this.maxLines = 2, this.style, super.key});

  final String text;
  final int maxLines;
  final TextStyle? style;

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

final class _ExpandableTextState extends State<ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        maxLines: widget.maxLines,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final cut = painter.didExceedMaxLines;
      painter.dispose();
      final text = Text(
        widget.text,
        style: style,
        maxLines: _expanded ? null : widget.maxLines,
        overflow: _expanded ? null : TextOverflow.ellipsis,
      );
      if (!cut) return text;
      return Semantics(
        button: true,
        hint: _expanded ? 'Shows less' : 'Shows all of it',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _expanded = !_expanded),
          child: text,
        ),
      );
    });
  }
}
