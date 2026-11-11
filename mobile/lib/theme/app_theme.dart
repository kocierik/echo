import 'package:flutter/material.dart';

/// Echo's colours. Panels sit on a quiet ground; two accents carry meaning:
/// [live] (orange) for what is happening now, [accent] (sky blue, the icon's) for
/// what is on, done or can be tapped. [attention] is the "Needs you" panel. The
/// graphite [chrome] is the hardware: the navigation bar, the device pill and puck.
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

  static const light = EchoPalette(
    background: Color(0xFFE9EAE7),
    surface: Color(0xFFF7F7F5),
    surface2: Color(0xFFECEDEA),
    text: Color(0xFF1F2326),
    text2: Color(0xFF5B6166),
    border: Color(0xFFE0E1DD),
    // Deep enough to read on the light ground (4.5:1 and more)
    accent: Color(0xFF0A6A94),
    accentSoft: Color(0xFFD3E7F1),
    onAccentSoft: Color(0xFF1E4A5F),
    tint: Color(0xFFE2EAEE),
    live: Color(0xFFE8590C),
    liveText: Color(0xFFAE430A),
    liveGlow: Color(0xFF5A3B2C),
    attention: Color(0xFFFFF1E2),
    onAttention: Color(0xFF8A4B12),
    onAttention2: Color(0xFF6B4A2B),
    green: Color(0xFF1E7A4D),
    amber: Color(0xFF925700),
    red: Color(0xFFB72F3B),
    chrome: Color(0xFF1F2326),
    chromeRaised: Color(0xFF2E3133),
    chromeLine: Color(0xFF464B4F),
    onChrome: Color(0xFFF7F7F5),
    onChromeMuted: Color(0xFFB9BBB6),
  );

  /// Near black, panels a step above it; never pure black.
  static const dark = EchoPalette(
    background: Color(0xFF0E0F10),
    surface: Color(0xFF1A1C1E),
    surface2: Color(0xFF232629),
    text: Color(0xFFECEDEA),
    text2: Color(0xFFA3A8AC),
    border: Color(0xFF2C2F32),
    // The icon's blue
    accent: Color(0xFF6CCBF5),
    accentSoft: Color(0xFF15303C),
    onAccentSoft: Color(0xFFA8DDF5),
    tint: Color(0xFF1B2428),
    live: Color(0xFFFF7A33),
    liveText: Color(0xFFFF9A5C),
    liveGlow: Color(0xFF45291B),
    attention: Color(0xFF2D2116),
    onAttention: Color(0xFFF2B57A),
    onAttention2: Color(0xFFD9B48E),
    green: Color(0xFF5CC98F),
    amber: Color(0xFFFFBD59),
    red: Color(0xFFFF6B74),
    chrome: Color(0xFF2A2D31),
    chromeRaised: Color(0xFF3D4145),
    chromeLine: Color(0xFF54595E),
    onChrome: Color(0xFFF7F7F5),
    onChromeMuted: Color(0xFF9EA3A7),
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
  static const fontFamily = 'Archivo';

  /// Archivo at 116% width: screen and panel titles.
  static const titleFamily = 'Archivo Expanded';
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
      fontFamily: fontFamily,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      scaffoldBackgroundColor: palette.background,
      canvasColor: palette.surface,
      colorScheme: ColorScheme(
        brightness: brightness,
        // Switches, checkboxes and progress are teal; buttons set their own ink
        primary: palette.accent,
        onPrimary: palette.background,
        secondary: palette.accent,
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
                : palette.text;
          }),
          foregroundColor: WidgetStatePropertyAll(palette.background),
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
      String family = fontFamily,
      Color? color,
      double height = 1.3,
    }) {
      return TextStyle(
        fontFamily: family,
        fontSize: size,
        fontWeight: weight,
        color: color ?? palette.text,
        height: height,
        letterSpacing: 0,
      );
    }

    return TextTheme(
      // Screen titles: "15 October", "Ask", "Memories"
      displayLarge: style(32, FontWeight.w700, family: titleFamily, height: 1.05),
      displayMedium: style(28, FontWeight.w700, family: titleFamily, height: 1.1),
      displaySmall: style(24, FontWeight.w700, family: titleFamily, height: 1.1),
      headlineLarge: style(30, FontWeight.w700, family: titleFamily),
      headlineMedium: style(20, FontWeight.w700, family: titleFamily),
      headlineSmall: style(20, FontWeight.w700, family: titleFamily),
      // App bar titles of the pages behind a screen
      titleLarge: style(20, FontWeight.w700, family: titleFamily),
      // Panel titles: "To do today", "Your day"
      titleMedium: style(16, FontWeight.w700, family: titleFamily),
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
