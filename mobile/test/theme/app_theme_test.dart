import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('light theme: panels on a quiet ground, Archivo', () {
    final theme = AppTheme.light;
    final palette = theme.extension<EchoPalette>()!;

    expect(theme.brightness, Brightness.light);
    expect(theme.textTheme.bodyMedium!.fontFamily, 'Archivo');
    expect(theme.textTheme.displayLarge!.fontFamily, 'Archivo Expanded');
    expect(palette.background, const Color(0xFFE9EAE7));
    expect(palette.surface, const Color(0xFFF7F7F5));
    expect(palette.text, const Color(0xFF1F2326));
    expect(palette.accent, const Color(0xFF0A6A94));
    expect(palette.live, const Color(0xFFE8590C));
    expect(palette.chrome, const Color(0xFF1F2326));
  });

  test('dark theme: near black, panels a step above, never pure black', () {
    final theme = AppTheme.dark;
    final palette = theme.extension<EchoPalette>()!;

    expect(theme.brightness, Brightness.dark);
    expect(palette.background, const Color(0xFF0E0F10));
    expect(palette.surface, const Color(0xFF1A1C1E));
    expect(palette.chrome, const Color(0xFF2A2D31));
    expect(palette.text, const Color(0xFFECEDEA));
    expect(palette.accent, const Color(0xFF6CCBF5));
    expect(palette.live, const Color(0xFFFF7A33));
  });

  test('main buttons are ink on the ground, links are blue', () {
    for (final theme in [AppTheme.dark, AppTheme.light]) {
      final palette = theme.extension<EchoPalette>()!;
      final filled = theme.filledButtonTheme.style!;
      expect(filled.backgroundColor!.resolve({}), palette.text);
      expect(filled.foregroundColor!.resolve({}), palette.background);
      expect(theme.textButtonTheme.style!.foregroundColor!.resolve({}), palette.accent);
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

  test('every control keeps a 44 pt target and text has no tracking', () {
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
      expect(theme.textTheme.displayLarge!.letterSpacing, 0);
      expect(theme.textTheme.bodyMedium!.letterSpacing, 0);
    }
  });
}
