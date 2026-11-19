import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Children in one rounded panel with a hairline between them, under an optional caption.
class EchoGroup extends StatelessWidget {
  const EchoGroup({required this.children, this.header, this.headerColor, super.key});

  final String? header;

  /// The header text colour; text2 when null.
  final Color? headerColor;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Semantics(
                header: true,
                child: Text(header!,
                    style: TextStyle(color: headerColor ?? palette.text2, fontSize: 13)),
              ),
            ),
          // A Material, so the rows' InkWell splashes show on the group's surface
          Material(
            color: palette.surface,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 0.5,
                      thickness: 0.5,
                      indent: 16,
                      color: palette.border,
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
