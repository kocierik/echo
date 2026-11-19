import 'package:echo_app/screens/settings/settings_components.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _page({double scale = 1, bool pushed = false}) {
  final page = SettingsPageScaffold(title: 'Privacy', children: [
    const SettingsSection('KEPT'),
    SettingsRow(icon: CupertinoIcons.lock, title: 'Audio', onTap: () {}),
    const SettingsRow(icon: CupertinoIcons.delete, title: 'Delete', destructive: true),
    const SettingsMessage('Saved'),
  ]);
  return MaterialApp(
    theme: AppTheme.dark,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: pushed
        ? Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => page)),
                child: const Text('go'),
              ),
            ),
          )
        : page,
  );
}

void main() {
  testWidgets('a settings page is a large title over inset grouped lists', (tester) async {
    await tester.pumpWidget(_page());
    expect(find.byType(CupertinoSliverNavigationBar), findsOneWidget);
    expect(find.byType(CupertinoListSection), findsOneWidget);
    expect(find.byType(CupertinoListTile), findsNWidgets(2));
    expect(find.text('KEPT'), findsOneWidget);
    expect(find.byType(CupertinoListTileChevron), findsOneWidget);
  });

  testWidgets('a destructive row is red and rows are at least 44 high', (tester) async {
    await tester.pumpWidget(_page());
    final red = EchoPalette.dark.red;
    final text = tester.widget<Text>(find.text('Delete'));
    expect(text.style?.color, red);
    for (final tile in tester.widgetList(find.byType(CupertinoListTile))) {
      expect(tester.getSize(find.byWidget(tile)).height, greaterThanOrEqualTo(44));
    }
  });

  testWidgets('big text wraps without overflowing', (tester) async {
    await tester.pumpWidget(_page(scale: 2.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pushed page has an accessible back button', (tester) async {
    await tester.pumpWidget(_page(pushed: true));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoNavigationBarBackButton), findsOneWidget);
    expect(find.bySemanticsLabel('Back'), findsOneWidget);
  });

  testWidgets('the last row clears the floating bar', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(bottom: 90)),
        child: SettingsPageScaffold(
          title: 'Long',
          children: [
            for (var i = 0; i < 20; i++)
              SettingsRow(icon: CupertinoIcons.lock, title: 'Row $i', onTap: () {}),
          ],
        ),
      ),
    ));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    final bottom = tester.getBottomLeft(find.text('Row 19')).dy;
    expect(bottom, lessThanOrEqualTo(tester.view.physicalSize.height / tester.view.devicePixelRatio - 90));
  });

  testWidgets('a section after rows heads the next group', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: SettingsPageScaffold(title: 'T', children: [
        const SettingsSection('ONE'),
        SettingsRow(icon: CupertinoIcons.lock, title: 'a', onTap: () {}),
        SettingsRow(icon: CupertinoIcons.lock, title: 'b', onTap: () {}),
        const SettingsSection('TWO'),
        SettingsRow(icon: CupertinoIcons.lock, title: 'c', onTap: () {}),
      ]),
    ));
    expect(find.byType(CupertinoListSection), findsNWidgets(2));
    expect(find.byType(SettingsSection), findsNothing);
    expect(find.text('TWO'), findsOneWidget);
  });

  testWidgets('a row value is secondary text', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: const SettingsPageScaffold(title: 'T', children: [
        SettingsRow(icon: CupertinoIcons.lock, title: 'a', value: 'On'),
      ]),
    ));
    expect(tester.widget<Text>(find.text('On')).style?.color, EchoPalette.dark.text2);
  });

  testWidgets('section and group headers are headings for VoiceOver', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: ListView(children: [
          const SettingsSection('KEPT'),
          SettingsGroup(header: 'GROUP', children: [
            SettingsRow(icon: CupertinoIcons.lock, title: 'Audio', onTap: () {}),
          ]),
        ]),
      ),
    ));
    for (final text in ['KEPT', 'GROUP']) {
      // The group's rows may merge into the header's node, so check the flag only
      expect(tester.getSemantics(find.text(text)).flagsCollection.isHeader, isTrue, reason: text);
    }
    handle.dispose();
  });
}
