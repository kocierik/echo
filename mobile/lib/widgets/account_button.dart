import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A person in a circle, in a header: opens the account sheet (account and settings).
final class AccountButton extends StatelessWidget {
  const AccountButton({required this.onTap, super.key});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: 'Account and settings',
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      padding: EdgeInsets.zero,
      icon: Semantics(
        label: 'Account',
        child: Icon(
          CupertinoIcons.person_crop_circle,
          size: 30,
          color: EchoPalette.of(context).text,
        ),
      ),
    );
  }
}
