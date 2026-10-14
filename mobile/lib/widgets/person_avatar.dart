import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Initials in a soft blue circle.
final class PersonAvatar extends StatelessWidget {
  const PersonAvatar({required this.initials, this.size = 40, super.key});

  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: palette.blue.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Text(
          initials,
          style: TextStyle(
            fontSize: size * 0.38,
            fontWeight: FontWeight.w600,
            color: palette.blue,
            height: 1,
          ),
        ),
      ),
    );
  }
}
