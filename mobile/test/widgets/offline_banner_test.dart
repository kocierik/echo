import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/offline_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('offline says since when, and goes away when fresh',
      (tester) async {
    final since = ValueNotifier<DateTime?>(null);
    addTearDown(since.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body:
            OfflineBanner(since: since, now: () => DateTime(2026, 10, 15, 18)),
      ),
    ));
    expect(find.byKey(const Key('offline-banner')), findsNothing);

    since.value = DateTime(2026, 10, 15, 14, 32);
    await tester.pump();
    expect(find.text('Offline · updated 14:32'), findsOneWidget);

    since.value = DateTime(2026, 10, 14, 9, 5);
    await tester.pump();
    expect(find.text('Offline · updated Yesterday 09:05'), findsOneWidget);

    since.value = null;
    await tester.pump();
    expect(find.byKey(const Key('offline-banner')), findsNothing);
  });
}
