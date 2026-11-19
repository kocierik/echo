import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/screen_header.dart';

/// The Library tab. A placeholder until its search, days and tiles land.
final class LibraryScreen extends StatelessWidget {
  const LibraryScreen({this.accountAction, super.key});

  /// The user's circle, top right.
  final Widget? accountAction;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: EchoPalette.of(context).background,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ScreenHeader(
              title: 'Library',
              actions: [if (accountAction != null) accountAction!],
            ),
          ],
        ),
      ),
    );
  }
}
