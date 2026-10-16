// Draws the launch screen artwork from the app's own device mark.
//
//   cd mobile && flutter test tool/splash_art_test.dart
//
// Writes the iOS LaunchImage (light and dark, 1x 2x 3x) and the Android launch marks
// (drawable-* and drawable-night-*). Run it again when EchoDeviceGlyph changes.
// Outside test/, so the suite never runs it.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/echo_device_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The mark's diameter in points, as the launch screens show it.
const _mark = 120.0;

/// Room under the mark for the word "Echo".
const _word = 56.0;

void main() {
  testWidgets('draws the launch artwork', (tester) async {
    await tester.runAsync(() async {
      final font = FontLoader(AppTheme.titleFamily)
        ..addFont(rootBundle.load('assets/fonts/ArchivoExpanded-Bold.ttf'));
      await font.load();
    });

    for (final dark in [false, true]) {
      // iOS: the mark and the word, centred by the storyboard on its colour
      for (final (scale, suffix) in [(1.0, ''), (2.0, '@2x'), (3.0, '@3x')]) {
        await _draw(
          tester,
          dark: dark,
          word: true,
          canvas: const Size(_mark, _mark + _word),
          mark: _mark,
          pixelRatio: scale,
          path: 'ios/Runner/Assets.xcassets/LaunchImage.imageset/'
              'LaunchImage${dark ? 'Dark' : ''}$suffix.png',
        );
      }
      final night = dark ? '-night' : '';
      for (final (density, scale) in [
        ('mdpi', 1.0),
        ('hdpi', 1.5),
        ('xhdpi', 2.0),
        ('xxhdpi', 3.0),
        ('xxxhdpi', 4.0),
      ]) {
        // Android before 12: the mark and the word on the launch background
        await _draw(
          tester,
          dark: dark,
          word: true,
          canvas: const Size(_mark, _mark + _word),
          mark: _mark,
          pixelRatio: scale,
          path:
              'android/app/src/main/res/drawable$night-$density/launch_mark.png',
        );
        // Android 12+: a 240 dp icon whose middle 160 dp circle is shown (no word)
        await _draw(
          tester,
          dark: dark,
          word: false,
          canvas: const Size(240, 240),
          mark: 150,
          pixelRatio: scale,
          path:
              'android/app/src/main/res/drawable$night-$density/splash_icon.png',
        );
      }
    }
  });
}

Future<void> _draw(
  WidgetTester tester, {
  required bool dark,
  required bool word,
  required Size canvas,
  required double mark,
  required double pixelRatio,
  required String path,
}) async {
  final boundary = GlobalKey();
  final palette = dark ? EchoPalette.dark : EchoPalette.light;
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? AppTheme.dark : AppTheme.light,
      debugShowCheckedModeBanner: false,
      home: Center(
        child: RepaintBoundary(
          key: boundary,
          // Material: text inside it has a style (no debug underline)
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox.fromSize(
              size: canvas,
              child: Column(
                mainAxisAlignment:
                    word ? MainAxisAlignment.start : MainAxisAlignment.center,
                children: [
                  // On the graphite ground a faint rim keeps the disc visible
                  DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: dark
                          ? Border.all(
                              color: palette.onChrome.withValues(alpha: 0.28),
                              width: 2)
                          : null,
                    ),
                    child: EchoDeviceGlyph(size: mark, glow: 0.6),
                  ),
                  if (word) ...[
                    const SizedBox(height: 14),
                    Text(
                      'Echo',
                      style: TextStyle(
                        fontFamily: AppTheme.titleFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 28,
                        height: 1,
                        color: palette.text,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: pixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}
