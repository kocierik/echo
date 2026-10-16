// Draws the launch screen artwork from the app's own device mark.
//
//   cd mobile && flutter test tool/splash_art_test.dart
//
// Writes the iOS LaunchImage (1x, 2x, 3x) and the Android launch marks. Run it again
// when EchoDeviceGlyph changes. Outside test/, so the suite never runs it.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/echo_device_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The mark's diameter in points, as the launch screens show it.
const _mark = 120.0;

void main() {
  testWidgets('draws the launch artwork', (tester) async {
    // iOS: the mark alone, centred by the storyboard on its background colour
    for (final (scale, suffix) in [(1.0, ''), (2.0, '@2x'), (3.0, '@3x')]) {
      await _draw(
        tester,
        canvas: _mark,
        mark: _mark,
        pixelRatio: scale,
        path: 'ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage$suffix.png',
      );
    }
    // Android before 12: the mark centred on the launch background
    for (final (density, scale) in [
      ('mdpi', 1.0),
      ('hdpi', 1.5),
      ('xhdpi', 2.0),
      ('xxhdpi', 3.0),
      ('xxxhdpi', 4.0),
    ]) {
      await _draw(
        tester,
        canvas: _mark,
        mark: _mark,
        pixelRatio: scale,
        path: 'android/app/src/main/res/drawable-$density/launch_mark.png',
      );
      // Android 12+: a 240 dp icon whose middle 160 dp circle is shown
      await _draw(
        tester,
        canvas: 240,
        mark: 150,
        pixelRatio: scale,
        path: 'android/app/src/main/res/drawable-$density/splash_icon.png',
      );
    }
  });
}

Future<void> _draw(
  WidgetTester tester, {
  required double canvas,
  required double mark,
  required double pixelRatio,
  required String path,
}) async {
  final boundary = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      debugShowCheckedModeBanner: false,
      home: Center(
        child: RepaintBoundary(
          key: boundary,
          child: SizedBox.square(
            dimension: canvas,
            child: Center(child: EchoDeviceGlyph(size: mark, glow: 0.6)),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: pixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}
