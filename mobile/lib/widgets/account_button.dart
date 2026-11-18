import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The user's circle, in a header: their initial (none when unknown). Opens the account sheet.
final class AccountButton extends StatelessWidget {
  const AccountButton({required this.onTap, this.initial, super.key});

  final VoidCallback onTap;
  final String? initial;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final letter = initial?.trim();
    return Semantics(
      label: 'Account',
      button: true,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: palette.accentSoft, shape: BoxShape.circle),
              child: letter == null || letter.isEmpty
                  ? null
                  : Text(
                      letter.characters.first.toUpperCase(),
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: palette.onAccentSoft,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
