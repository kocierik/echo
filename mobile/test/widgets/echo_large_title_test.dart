import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/echo_grouped.dart';
import 'package:echo_app/widgets/echo_large_title.dart';
import 'package:echo_app/widgets/echo_nav_bar.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget home, {double scale = 1}) => MaterialApp(
      theme: AppTheme.dark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    );

Widget _rows(int n) => SliverList(
      delegate: SliverChildListDelegate([
        for (var i = 0; i < n; i++) SizedBox(height: 60, child: Text('Row $i')),
      ]),
    );

void main() {
  testWidgets('the large title collapses when scrolled', (tester) async {
    // The large title only exists in portrait; the default test surface is landscape.
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A pushed page: it has the iOS bar, with its back button
    await tester.pumpWidget(_app(Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => EchoLargeTitlePage(title: 'Person', slivers: [_rows(30)]),
        )),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    double barHeight() =>
        (tester.renderObject(find.byType(CupertinoSliverNavigationBar))
                as RenderSliver)
            .geometry!
            .paintExtent;
    final expanded = barHeight();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(barHeight(), lessThan(expanded - 30));
  });

  testWidgets('a tab\'s first page: title and circle on one row, nothing above', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(EchoLargeTitlePage(
      title: 'Library',
      trailing: const SizedBox(key: Key('circle'), width: 44, height: 44),
      slivers: [_rows(3)],
    )));

    expect(find.byType(CupertinoSliverNavigationBar), findsNothing);
    final title = tester.getRect(find.byKey(const Key('large-title')));
    final circle = tester.getRect(find.byKey(const Key('circle')));
    expect((title.center.dy - circle.center.dy).abs(), lessThan(4));
    expect(title.top, lessThan(24));
  });

  testWidgets('pulling down runs onRefresh', (tester) async {
    var refreshed = 0;
    await tester.pumpWidget(_app(EchoLargeTitlePage(
      title: 'Today',
      onRefresh: () async => refreshed++,
      slivers: [_rows(30)],
    )));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(refreshed, 1);
  });

  testWidgets('without onRefresh there is no refresh control', (tester) async {
    await tester.pumpWidget(
        _app(EchoLargeTitlePage(title: 'Today', slivers: [_rows(3)])));
    expect(find.byType(CupertinoSliverRefreshControl), findsNothing);
  });

  testWidgets('the end clears the bar, pushed or at a tab root',
      (tester) async {
    Future<double> gap(Widget home) async {
      await tester.pumpWidget(_app(home));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -5000));
      await tester.pumpAndSettle();
      final screen =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      return screen - tester.getBottomLeft(find.text('Row 19')).dy;
    }

    final page = EchoLargeTitlePage(title: 'Long', slivers: [_rows(20)]);
    expect(
      await gap(MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(bottom: 90)),
        child: page,
      )),
      greaterThanOrEqualTo(90),
    );
    expect(
      await gap(EchoShellInsets(bottom: 90, child: page)),
      greaterThanOrEqualTo(90),
    );
  });

  testWidgets('a trailing widget shows and big text does not overflow',
      (tester) async {
    await tester.pumpWidget(_app(
      EchoLargeTitlePage(
        title: 'Today',
        trailing: const Icon(CupertinoIcons.person_crop_circle),
        slivers: [_rows(3)],
      ),
      scale: 2.5,
    ));
    expect(find.byIcon(CupertinoIcons.person_crop_circle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a group draws n-1 hairlines and its header', (tester) async {
    await tester.pumpWidget(_app(const Scaffold(
      body: EchoGroup(
          header: 'KEPT', children: [Text('a'), Text('b'), Text('c')]),
    )));
    expect(find.text('KEPT'), findsOneWidget);
    expect(find.byType(Divider), findsNWidgets(2));
  });

  testWidgets('a group of one has no hairline and no header when none given',
      (tester) async {
    await tester.pumpWidget(
        _app(const Scaffold(body: EchoGroup(children: [Text('a')]))));
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('a row with an InkWell splashes on the group surface', (tester) async {
    await tester.pumpWidget(_app(Scaffold(
      body: EchoGroup(children: [InkWell(onTap: () {}, child: const Text('a'))]),
    )));
    final material = tester.widget<Material>(
        find.ancestor(of: find.byType(InkWell), matching: find.byType(Material)).first);
    expect(material.color, EchoPalette.dark.surface);
  });

  testWidgets('an EchoGroup header is a screen-reader heading', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(const Scaffold(
      body: EchoGroup(header: 'Overdue · 1', children: [Text('row')]),
    )));

    expect(
      tester.getSemantics(find.text('Overdue · 1')),
      matchesSemantics(label: 'Overdue · 1', isHeader: true),
    );
    handle.dispose();
  });
}
