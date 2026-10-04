import 'package:flutter/material.dart';

@immutable
final class EchoPalette extends ThemeExtension<EchoPalette> {
  const EchoPalette({
    required this.background,
    required this.surface,
    required this.surface2,
    required this.text,
    required this.text2,
    required this.blue,
    required this.green,
    required this.amber,
    required this.red,
    required this.border,
  });

  static const dark = EchoPalette(
    background: Color(0xFF080A0D),
    surface: Color(0xFF111419),
    surface2: Color(0xFF171B21),
    text: Color(0xFFF4F6F8),
    text2: Color(0xFF9CA3AE),
    blue: Color(0xFF4385FF),
    green: Color(0xFF46D69A),
    amber: Color(0xFFFFBD59),
    red: Color(0xFFFF6B74),
    border: Color(0xFF252A32),
  );

  static const light = EchoPalette(
    background: Color(0xFFF7F8FA),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFEDF0F4),
    text: Color(0xFF191C21),
    text2: Color(0xFF6B727C),
    blue: Color(0xFF286FD4),
    green: Color(0xFF168A5B),
    amber: Color(0xFFA96500),
    red: Color(0xFFB72F3B),
    border: Color(0xFFDFE3E8),
  );

  final Color background;
  final Color surface;
  final Color surface2;
  final Color text;
  final Color text2;
  final Color blue;
  final Color green;
  final Color amber;
  final Color red;
  final Color border;

  static EchoPalette of(BuildContext context) {
    return Theme.of(context).extension<EchoPalette>()!;
  }

  @override
  EchoPalette copyWith({
    Color? background,
    Color? surface,
    Color? surface2,
    Color? text,
    Color? text2,
    Color? blue,
    Color? green,
    Color? amber,
    Color? red,
    Color? border,
  }) {
    return EchoPalette(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      text: text ?? this.text,
      text2: text2 ?? this.text2,
      blue: blue ?? this.blue,
      green: green ?? this.green,
      amber: amber ?? this.amber,
      red: red ?? this.red,
      border: border ?? this.border,
    );
  }

  @override
  EchoPalette lerp(covariant EchoPalette? other, double t) {
    if (other == null) return this;
    return EchoPalette(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      text: Color.lerp(text, other.text, t)!,
      text2: Color.lerp(text2, other.text2, t)!,
      blue: Color.lerp(blue, other.blue, t)!,
      green: Color.lerp(green, other.green, t)!,
      amber: Color.lerp(amber, other.amber, t)!,
      red: Color.lerp(red, other.red, t)!,
      border: Color.lerp(border, other.border, t)!,
    );
  }
}

class AppColors {
  static const bgDeep = Color(0xFF080A0D);
  static const bgBase = Color(0xFF080A0D);
  static const bgElevated = Color(0xFF111419);
  static const surface = Color(0xFF171B21);
  static const foreground = Color(0xFFF4F6F8);
  static const foregroundMuted = Color(0xFF9CA3AE);
  static const accent = Color(0xFF4385FF);
  static const accentGlow = Color(0x334385FF);
  static const border = Color(0xFF252A32);
  static const success = Color(0xFF46D69A);
  static const warning = Color(0xFFFFBD59);
  static const error = Color(0xFFFF6B74);
}

class AppTheme {
  static const fontFamily = 'DM Sans';
  static const minimumInteractiveDimension = 44.0;

  static ThemeData get dark => _build(Brightness.dark, EchoPalette.dark);
  static ThemeData get light => _build(Brightness.light, EchoPalette.light);

  static ThemeData _build(Brightness brightness, EchoPalette palette) {
    final textTheme = _textTheme(palette);
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: palette.border),
    );
    final componentShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
    );
    const minimumSize = WidgetStatePropertyAll(
      Size(minimumInteractiveDimension, minimumInteractiveDimension),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: fontFamily,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      scaffoldBackgroundColor: palette.background,
      canvasColor: palette.surface,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: palette.blue,
        onPrimary: Colors.white,
        secondary: palette.green,
        onSecondary: palette.background,
        error: palette.red,
        onError: Colors.white,
        surface: palette.surface,
        onSurface: palette.text,
      ),
      extensions: <ThemeExtension<dynamic>>[palette],
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      cardTheme: CardThemeData(
        color: palette.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: componentShape.copyWith(
          side: BorderSide(color: palette.border),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: palette.background,
        foregroundColor: palette.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
        iconTheme: IconThemeData(color: palette.text2),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surface2,
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: palette.blue, width: 2),
        ),
        errorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: palette.red),
        ),
        focusedErrorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: palette.red, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        hintStyle: textTheme.bodyMedium!.copyWith(color: palette.text2),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 64,
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: palette.blue.withValues(alpha: 0.16),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return IconThemeData(
            color: states.contains(WidgetState.selected)
                ? palette.blue
                : palette.text2,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return textTheme.labelSmall!.copyWith(
            color: states.contains(WidgetState.selected)
                ? palette.blue
                : palette.text2,
          );
        }),
      ),
      dividerTheme: DividerThemeData(
        color: palette.border,
        thickness: 1,
        space: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: componentShape,
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          minimumSize: minimumSize,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          backgroundColor: WidgetStatePropertyAll(palette.blue),
          foregroundColor: const WidgetStatePropertyAll(Colors.white),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
          shape: WidgetStatePropertyAll(componentShape),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: minimumSize,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          backgroundColor: WidgetStatePropertyAll(palette.blue),
          foregroundColor: const WidgetStatePropertyAll(Colors.white),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
          shape: WidgetStatePropertyAll(componentShape),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: minimumSize,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          foregroundColor: WidgetStatePropertyAll(palette.blue),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
          side: WidgetStatePropertyAll(BorderSide(color: palette.border)),
          shape: WidgetStatePropertyAll(componentShape),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: minimumSize,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          foregroundColor: WidgetStatePropertyAll(palette.blue),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
          shape: WidgetStatePropertyAll(componentShape),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: minimumSize,
          foregroundColor: WidgetStatePropertyAll(palette.text2),
          shape: WidgetStatePropertyAll(componentShape),
        ),
      ),
    );
  }

  static TextTheme _textTheme(EchoPalette palette) {
    TextStyle style(
      double size,
      FontWeight weight, {
      Color? color,
      double height = 1.25,
    }) {
      return TextStyle(
        fontFamily: fontFamily,
        fontSize: size,
        fontWeight: weight,
        color: color ?? palette.text,
        height: height,
        letterSpacing: 0,
      );
    }

    return TextTheme(
      displayLarge: style(24, FontWeight.w600),
      displayMedium: style(24, FontWeight.w600),
      displaySmall: style(24, FontWeight.w600),
      headlineLarge: style(20, FontWeight.w600),
      headlineMedium: style(20, FontWeight.w600),
      headlineSmall: style(20, FontWeight.w600),
      titleLarge: style(20, FontWeight.w600),
      titleMedium: style(16, FontWeight.w600),
      titleSmall: style(14, FontWeight.w600),
      bodyLarge: style(16, FontWeight.w400, height: 1.5),
      bodyMedium: style(16, FontWeight.w400, height: 1.5),
      bodySmall: style(
        14,
        FontWeight.w400,
        color: palette.text2,
        height: 1.4,
      ),
      labelLarge: style(16, FontWeight.w600),
      labelMedium: style(14, FontWeight.w600),
      labelSmall: style(14, FontWeight.w600, color: palette.text2),
    );
  }
}
