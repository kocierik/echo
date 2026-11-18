import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Graphite: warm white ground, white panels, the darker azure', () {
    final palette = AppTheme.light.extension<EchoPalette>()!;
    expect(palette.background, const Color(0xFFF5F5F2));
    expect(palette.surface, const Color(0xFFFFFFFF));
    expect(palette.text, const Color(0xFF1D1D1F));
    expect(palette.text2, const Color(0xFF6E6E73));
    expect(palette.accent, const Color(0xFF0A6FD6));
    expect(palette.onAccent, const Color(0xFFFFFFFF));
    expect(palette.live, palette.accent);
  });

  test('Midnight: black ground, graphite panels, the pendant azure', () {
    final palette = AppTheme.dark.extension<EchoPalette>()!;
    expect(palette.background, const Color(0xFF000000));
    expect(palette.surface, const Color(0xFF1C1C1E));
    expect(palette.text, const Color(0xFFE8E8ED));
    expect(palette.accent, const Color(0xFF64D2FF));
    expect(palette.onAccent, const Color(0xFF00141C));
    expect(palette.red, const Color(0xFFFF453A));
  });

  test('the primary button is the accent, links are the accent', () {
    for (final theme in [AppTheme.dark, AppTheme.light]) {
      final palette = theme.extension<EchoPalette>()!;
      final filled = theme.filledButtonTheme.style!;
      expect(filled.backgroundColor!.resolve({}), palette.accent);
      expect(filled.foregroundColor!.resolve({}), palette.onAccent);
      expect(theme.textButtonTheme.style!.foregroundColor!.resolve({}), palette.accent);
    }
  });

  test('no Archivo: the platform font (San Francisco on iOS)', () {
    for (final theme in [AppTheme.dark, AppTheme.light]) {
      expect(theme.textTheme.bodyMedium!.fontFamily, isNot('Archivo'));
      expect(theme.textTheme.displayLarge!.fontFamily, isNot('Archivo Expanded'));
    }
  });

  test('pages slide in from the side and swipe back, on every platform', () {
    for (final theme in [AppTheme.dark, AppTheme.light]) {
      for (final platform in TargetPlatform.values) {
        expect(theme.pageTransitionsTheme.builders[platform], isA<CupertinoPageTransitionsBuilder>());
      }
    }
  });

  test('the blue accent reads on its grounds (4.5:1 and more)', () {
    double contrast(Color a, Color b) {
      final (light, dark) = a.computeLuminance() > b.computeLuminance()
          ? (a.computeLuminance(), b.computeLuminance())
          : (b.computeLuminance(), a.computeLuminance());
      return (light + 0.05) / (dark + 0.05);
    }

    for (final theme in [AppTheme.dark, AppTheme.light]) {
      final palette = theme.extension<EchoPalette>()!;
      expect(contrast(palette.accent, palette.surface), greaterThanOrEqualTo(4.5));
      expect(contrast(palette.accent, palette.background), greaterThanOrEqualTo(4.5));
    }
  });

  test('every control keeps a 44 pt target and text tracking is left to the platform', () {
    for (final theme in [AppTheme.dark, AppTheme.light]) {
      for (final style in [
        theme.elevatedButtonTheme.style!,
        theme.filledButtonTheme.style!,
        theme.outlinedButtonTheme.style!,
        theme.textButtonTheme.style!,
        theme.iconButtonTheme.style!,
      ]) {
        final minimum = style.minimumSize!.resolve({})!;
        expect(minimum.width, greaterThanOrEqualTo(44));
        expect(minimum.height, greaterThanOrEqualTo(44));
      }
      expect(theme.textTheme.displayLarge!.letterSpacing, isNull);
      expect(theme.textTheme.bodyMedium!.letterSpacing, isNull);
    }
  });
}
