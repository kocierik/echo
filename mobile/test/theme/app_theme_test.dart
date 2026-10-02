import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dark theme uses the approved palette and typography', () {
    final theme = AppTheme.dark;
    final palette = theme.extension<EchoPalette>()!;

    expect(theme.brightness, Brightness.dark);
    expect(theme.textTheme.bodyMedium!.fontFamily, 'DM Sans');
    expect(palette.background, const Color(0xFF080A0D));
    expect(palette.surface, const Color(0xFF111419));
    expect(palette.surface2, const Color(0xFF171B21));
    expect(palette.text, const Color(0xFFF4F6F8));
    expect(palette.text2, const Color(0xFF9CA3AE));
    expect(palette.blue, const Color(0xFF4385FF));
    expect(palette.green, const Color(0xFF46D69A));
    expect(palette.amber, const Color(0xFFFFBD59));
    expect(palette.red, const Color(0xFFFF6B74));
    expect(palette.border, const Color(0xFF252A32));
  });

  test('light theme uses the approved accessible palette', () {
    final theme = AppTheme.light;
    final palette = theme.extension<EchoPalette>()!;

    expect(theme.brightness, Brightness.light);
    expect(theme.textTheme.bodyMedium!.fontFamily, 'DM Sans');
    expect(palette.background, const Color(0xFFF7F8FA));
    expect(palette.surface, const Color(0xFFFFFFFF));
    expect(palette.surface2, const Color(0xFFEDF0F4));
    expect(palette.text, const Color(0xFF191C21));
    expect(palette.text2, const Color(0xFF6B727C));
    expect(palette.blue, const Color(0xFF286FD4));
    expect(palette.green, const Color(0xFF168A5B));
    expect(palette.amber, const Color(0xFFA96500));
    expect(palette.red, const Color(0xFFB72F3B));
    expect(palette.border, const Color(0xFFDFE3E8));
  });

  test('component geometry and text spacing meet the mobile baseline', () {
    for (final theme in [AppTheme.dark, AppTheme.light]) {
      final cardShape = theme.cardTheme.shape! as RoundedRectangleBorder;
      final cardRadius = cardShape.borderRadius as BorderRadius;
      final elevatedMinimum =
          theme.elevatedButtonTheme.style!.minimumSize!.resolve({})!;
        final filledMinimum =
          theme.filledButtonTheme.style!.minimumSize!.resolve({})!;
      final outlinedMinimum =
          theme.outlinedButtonTheme.style!.minimumSize!.resolve({})!;
      final textMinimum =
          theme.textButtonTheme.style!.minimumSize!.resolve({})!;
        final iconMinimum =
          theme.iconButtonTheme.style!.minimumSize!.resolve({})!;

      expect(cardRadius.topLeft.x, lessThanOrEqualTo(8));
      expect(elevatedMinimum.width, greaterThanOrEqualTo(44));
      expect(elevatedMinimum.height, greaterThanOrEqualTo(44));
        expect(filledMinimum.width, greaterThanOrEqualTo(44));
        expect(filledMinimum.height, greaterThanOrEqualTo(44));
      expect(outlinedMinimum.width, greaterThanOrEqualTo(44));
      expect(outlinedMinimum.height, greaterThanOrEqualTo(44));
      expect(textMinimum.width, greaterThanOrEqualTo(44));
      expect(textMinimum.height, greaterThanOrEqualTo(44));
        expect(iconMinimum.width, greaterThanOrEqualTo(44));
        expect(iconMinimum.height, greaterThanOrEqualTo(44));
      expect(theme.textTheme.displayLarge!.letterSpacing, 0);
      expect(theme.textTheme.titleLarge!.letterSpacing, 0);
    }
  });
}