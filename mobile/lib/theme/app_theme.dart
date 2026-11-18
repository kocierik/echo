import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Echo's colours: Midnight (dark) and Graphite (light), one azure [accent]. The
/// legacy roles ([live], [attention], [chrome]...) keep their names and now map to
/// the accent, a normal panel and the translucent bar colours.
@immutable
final class EchoPalette extends ThemeExtension<EchoPalette> {
  const EchoPalette({
    required this.background,
    required this.surface,
    required this.surface2,
    required this.text,
    required this.text2,
    required this.border,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.onAccentSoft,
    required this.tint,
    required this.live,
    required this.liveText,
    required this.liveGlow,
    required this.attention,
    required this.onAttention,
    required this.onAttention2,
    required this.green,
    required this.amber,
    required this.red,
    required this.chrome,
    required this.chromeRaised,
    required this.chromeLine,
    required this.onChrome,
    required this.onChromeMuted,
  });

  /// Graphite: a warm white ground, white panels, the darker azure.
  static const light = EchoPalette(
    background: Color(0xFFF5F5F2),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF0F0ED),
    text: Color(0xFF1D1D1F),
    text2: Color(0xFF6E6E73),
    border: Color(0xFFE3E3E0),
    accent: Color(0xFF0A6FD6),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFE3EEF9),
    onAccentSoft: Color(0xFF0A4F9E),
    tint: Color(0xFFE3EEF9),
    live: Color(0xFF0A6FD6),
    liveText: Color(0xFF0A6FD6),
    liveGlow: Color(0xFFE3EEF9),
    attention: Color(0xFFFFFFFF),
    onAttention: Color(0xFF1D1D1F),
    onAttention2: Color(0xFF6E6E73),
    green: Color(0xFF1E7A4D),
    amber: Color(0xFF8A5A00),
    red: Color(0xFFD70015),
    chrome: Color(0xEBF5F5F2),
    chromeRaised: Color(0xFFF0F0ED),
    chromeLine: Color(0xFFE3E3E0),
    onChrome: Color(0xFF1D1D1F),
    onChromeMuted: Color(0xFF6E6E73),
  );

  /// Midnight: black ground, graphite panels, the pendant's azure.
  static const dark = EchoPalette(
    background: Color(0xFF000000),
    surface: Color(0xFF1C1C1E),
    surface2: Color(0xFF2C2C2E),
    text: Color(0xFFE8E8ED),
    text2: Color(0xFF8E8E93),
    border: Color(0xFF38383A),
    accent: Color(0xFF64D2FF),
    onAccent: Color(0xFF00141C),
    accentSoft: Color(0xFF0B2A36),
    onAccentSoft: Color(0xFF64D2FF),
    tint: Color(0xFF0B2A36),
    live: Color(0xFF64D2FF),
    liveText: Color(0xFF64D2FF),
    liveGlow: Color(0xFF0B2A36),
    attention: Color(0xFF1C1C1E),
    onAttention: Color(0xFFE8E8ED),
    onAttention2: Color(0xFF8E8E93),
    green: Color(0xFF30D158),
    amber: Color(0xFFFFD60A),
    red: Color(0xFFFF453A),
    chrome: Color(0xEB121214),
    chromeRaised: Color(0xFF2C2C2E),
    chromeLine: Color(0xFF38383A),
    onChrome: Color(0xFFE8E8ED),
    onChromeMuted: Color(0xFF8E8E93),
  );

  /// The ground the panels sit on.
  final Color background;

  /// A panel.
  final Color surface;

  /// A tile or field inside a panel.
  final Color surface2;
  final Color text;
  final Color text2;

  /// Hairlines between rows inside a panel.
  final Color border;

  /// On, done, selected, a link (teal).
  final Color accent;

  /// Text and icons on an accent fill.
  final Color onAccent;
  final Color accentSoft;
  final Color onAccentSoft;

  /// A neutral cool block (a conversation in the day's timeline).
  final Color tint;

  /// Happening now: the LED, recording, dictation (orange).
  final Color live;

  /// [live] for small text, readable on the ground.
  final Color liveText;
  final Color liveGlow;

  /// The "Needs you" panel and its text.
  final Color attention;
  final Color onAttention;
  final Color onAttention2;
  final Color green;
  final Color amber;
  final Color red;

  /// Graphite hardware: the navigation bar, the device pill and puck.
  final Color chrome;
  final Color chromeRaised;
  final Color chromeLine;
  final Color onChrome;
  final Color onChromeMuted;

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
    Color? border,
    Color? accent,
    Color? onAccent,
    Color? accentSoft,
    Color? onAccentSoft,
    Color? tint,
    Color? live,
    Color? liveText,
    Color? liveGlow,
    Color? attention,
    Color? onAttention,
    Color? onAttention2,
    Color? green,
    Color? amber,
    Color? red,
    Color? chrome,
    Color? chromeRaised,
    Color? chromeLine,
    Color? onChrome,
    Color? onChromeMuted,
  }) {
    return EchoPalette(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      text: text ?? this.text,
      text2: text2 ?? this.text2,
      border: border ?? this.border,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      accentSoft: accentSoft ?? this.accentSoft,
      onAccentSoft: onAccentSoft ?? this.onAccentSoft,
      tint: tint ?? this.tint,
      live: live ?? this.live,
      liveText: liveText ?? this.liveText,
      liveGlow: liveGlow ?? this.liveGlow,
      attention: attention ?? this.attention,
      onAttention: onAttention ?? this.onAttention,
      onAttention2: onAttention2 ?? this.onAttention2,
      green: green ?? this.green,
      amber: amber ?? this.amber,
      red: red ?? this.red,
      chrome: chrome ?? this.chrome,
      chromeRaised: chromeRaised ?? this.chromeRaised,
      chromeLine: chromeLine ?? this.chromeLine,
      onChrome: onChrome ?? this.onChrome,
      onChromeMuted: onChromeMuted ?? this.onChromeMuted,
    );
  }

  @override
  EchoPalette lerp(covariant EchoPalette? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return EchoPalette(
      background: mix(background, other.background),
      surface: mix(surface, other.surface),
      surface2: mix(surface2, other.surface2),
      text: mix(text, other.text),
      text2: mix(text2, other.text2),
      border: mix(border, other.border),
      accent: mix(accent, other.accent),
      onAccent: mix(onAccent, other.onAccent),
      accentSoft: mix(accentSoft, other.accentSoft),
      onAccentSoft: mix(onAccentSoft, other.onAccentSoft),
      tint: mix(tint, other.tint),
      live: mix(live, other.live),
      liveText: mix(liveText, other.liveText),
      liveGlow: mix(liveGlow, other.liveGlow),
      attention: mix(attention, other.attention),
      onAttention: mix(onAttention, other.onAttention),
      onAttention2: mix(onAttention2, other.onAttention2),
      green: mix(green, other.green),
      amber: mix(amber, other.amber),
      red: mix(red, other.red),
      chrome: mix(chrome, other.chrome),
      chromeRaised: mix(chromeRaised, other.chromeRaised),
      chromeLine: mix(chromeLine, other.chromeLine),
      onChrome: mix(onChrome, other.onChrome),
      onChromeMuted: mix(onChromeMuted, other.onChromeMuted),
    );
  }
}

class AppTheme {
  static const minimumInteractiveDimension = 44.0;

  /// Panels and the tiles inside them.
  static const panelRadius = 22.0;
  static const tileRadius = 14.0;

  static ThemeData get dark => _build(Brightness.dark, EchoPalette.dark);
  static ThemeData get light => _build(Brightness.light, EchoPalette.light);

  static ThemeData _build(Brightness brightness, EchoPalette palette) {
    final textTheme = _textTheme(palette);
    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(24),
      borderSide: BorderSide.none,
    );
    const pill = StadiumBorder();
    const minimumSize = WidgetStatePropertyAll(
      Size(minimumInteractiveDimension, minimumInteractiveDimension),
    );
    const buttonPadding = WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          for (final p in TargetPlatform.values) p: const CupertinoPageTransitionsBuilder(),
        },
      ),
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      scaffoldBackgroundColor: palette.background,
      canvasColor: palette.surface,
      colorScheme: ColorScheme(
        brightness: brightness,
        // Switches, checkboxes and progress are teal; buttons set their own ink
        primary: palette.accent,
        onPrimary: palette.onAccent,
        secondary: palette.accent,
        onSecondary: palette.onAccent,
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(panelRadius),
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
        iconTheme: IconThemeData(color: palette.text),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surface,
        border: fieldBorder,
        enabledBorder: fieldBorder,
        disabledBorder: fieldBorder,
        focusedBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: palette.accent, width: 2),
        ),
        errorBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: palette.red),
        ),
        focusedErrorBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: palette.red, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        hintStyle: textTheme.bodyMedium!.copyWith(color: palette.text2),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: minimumSize,
          textStyle: WidgetStatePropertyAll(textTheme.labelMedium),
          side: const WidgetStatePropertyAll(BorderSide.none),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? palette.text
                : palette.surface;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? palette.background
                : palette.text;
          }),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: palette.border,
        thickness: 1,
        space: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(panelRadius),
        ),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.background,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(panelRadius)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.chrome,
        contentTextStyle: textTheme.bodyMedium!.copyWith(color: palette.onChrome),
        actionTextColor: palette.accentSoft,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        side: BorderSide(color: palette.text2, width: 1.5),
      ),
      // The main action is ink on the ground: graphite in light, light in dark
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          minimumSize: minimumSize,
          padding: buttonPadding,
          elevation: const WidgetStatePropertyAll(0),
          backgroundColor: WidgetStatePropertyAll(palette.text),
          foregroundColor: WidgetStatePropertyAll(palette.background),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
          shape: const WidgetStatePropertyAll(pill),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: minimumSize,
          padding: buttonPadding,
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.disabled)
                ? palette.text.withValues(alpha: 0.24)
                : palette.accent;
          }),
          foregroundColor: WidgetStatePropertyAll(palette.onAccent),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
          shape: const WidgetStatePropertyAll(pill),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: minimumSize,
          padding: buttonPadding,
          foregroundColor: WidgetStatePropertyAll(palette.text),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
          side: WidgetStatePropertyAll(BorderSide(color: palette.chromeLine.withValues(alpha: 0.4))),
          shape: const WidgetStatePropertyAll(pill),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: minimumSize,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          foregroundColor: WidgetStatePropertyAll(palette.accent),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
          shape: const WidgetStatePropertyAll(pill),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: minimumSize,
          foregroundColor: WidgetStatePropertyAll(palette.text),
          shape: const WidgetStatePropertyAll(CircleBorder()),
        ),
      ),
    );
  }

  static TextTheme _textTheme(EchoPalette palette) {
    TextStyle style(
      double size,
      FontWeight weight, {
      Color? color,
      double height = 1.3,
    }) {
      return TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color ?? palette.text,
        height: height,
      );
    }

    return TextTheme(
      // Screen titles: "15 October", "Ask", "Memories"
      displayLarge: style(32, FontWeight.w700, height: 1.05),
      displayMedium: style(28, FontWeight.w700, height: 1.1),
      displaySmall: style(24, FontWeight.w700, height: 1.1),
      headlineLarge: style(30, FontWeight.w700),
      headlineMedium: style(20, FontWeight.w700),
      headlineSmall: style(20, FontWeight.w700),
      // App bar titles of the pages behind a screen
      titleLarge: style(20, FontWeight.w700),
      // Panel titles: "To do today", "Your day"
      titleMedium: style(16, FontWeight.w700),
      // Row titles
      titleSmall: style(15, FontWeight.w600),
      bodyLarge: style(17, FontWeight.w400, height: 1.45),
      bodyMedium: style(15, FontWeight.w400, height: 1.5),
      bodySmall: style(13, FontWeight.w400, color: palette.text2, height: 1.4),
      labelLarge: style(15, FontWeight.w600),
      labelMedium: style(13, FontWeight.w600),
      labelSmall: style(12, FontWeight.w600, color: palette.text2),
    );
  }
}
