import 'package:flutter/material.dart';

class AppColors {
  static const bgDeep = Color(0xFF020203);
  static const bgBase = Color(0xFF0A0A0F);
  static const bgElevated = Color(0xFF0A0A0C);
  static const surface = Color(0x0DFFFFFF); // rgba(255,255,255,0.05)
  static const foreground = Color(0xFFEDEDEF);
  static const foregroundMuted = Color(0xFF8A8F98);
  static const accent = Color(0xFF5E6AD2);
  static const accentGlow = Color(0x335E6AD2); // rgba(94,106,210,0.2)
  static const border = Color(0x14FFFFFF); // rgba(255,255,255,0.08)
  static const success = Color(0xFF30D158);
  static const error = Color(0xFFFF453A);
}

class AppTheme {
  static ThemeData get dark {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bgDeep,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.accent,
        secondary: AppColors.accent,
        surface: AppColors.bgElevated,
        error: AppColors.error,
        onPrimary: Colors.white,
        onSurface: AppColors.foreground,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.foreground,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: AppColors.foregroundMuted),
      ),
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          color: AppColors.foreground,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
        ),
        bodyMedium: TextStyle(
          color: AppColors.foreground,
          fontSize: 15,
          height: 1.5,
        ),
        bodySmall: TextStyle(
          color: AppColors.foregroundMuted,
          fontSize: 12,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.bgElevated,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: const BorderSide(color: AppColors.accent, width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        hintStyle: const TextStyle(color: AppColors.foregroundMuted, fontSize: 15),
      ),
    );
  }
}
