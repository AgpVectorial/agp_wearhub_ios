import 'package:flutter/material.dart';

const Color kGold = Color(0xFFFFC107); // accent gold
const Color kBlack = Color(0xFF000000); // background
const Color kSurface = Color(0xFF111111); // cards/panels
const Color kOnBlack = Color(0xFFEAEAEA); // text on black
const Color kOnSurface = Color(0xFFE0E0E0);

ThemeData appDarkTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  final scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: kGold,
    onPrimary: Colors.black,
    secondary: const Color(0xFFFFD54F),
    onSecondary: Colors.black,
    error: const Color(0xFFFF5252),
    onError: Colors.black,
    surface: kSurface,
    onSurface: kOnSurface,
  );

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: kBlack,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: kBlack,
      foregroundColor: kOnBlack,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: kOnBlack,
        letterSpacing: 0.2,
      ),
    ),
    // <-- Diferența importantă: CardThemeData (nu CardTheme)
    cardTheme: CardThemeData(
      color: kSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        side: BorderSide.none,
      ),
      margin: EdgeInsets.zero,
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: kOnSurface,
      textColor: kOnSurface,
      tileColor: Colors.transparent,
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: const Color(0xFF1B1B1B),
      selectedColor: kGold.withOpacity(0.18),
      labelStyle: const TextStyle(color: kOnSurface),
      side: BorderSide.none,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFF2A2A2A),
      thickness: 1,
      space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.disabled)) return kGold.withOpacity(0.35);
          return kGold;
        }),
        foregroundColor: WidgetStateProperty.all(Colors.black),
        elevation: WidgetStateProperty.all(0),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(
        padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        backgroundColor: WidgetStateProperty.all(const Color(0xFF1E1E1E)),
        foregroundColor: WidgetStateProperty.all(kOnSurface),
        elevation: WidgetStateProperty.all(0),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        side: WidgetStateProperty.all(BorderSide(color: kGold.withOpacity(0.6), width: 1)),
        foregroundColor: WidgetStateProperty.all(kGold),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        side: WidgetStateProperty.all(const BorderSide(color: Color(0xFF2A2A2A))),
        backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.selected)) return kGold.withOpacity(0.18);
          return const Color(0xFF141414);
        }),
        foregroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.selected)) return kGold;
          return kOnSurface;
        }),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
        visualDensity: VisualDensity.compact,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: kGold),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF1C1C1C),
      contentTextStyle: TextStyle(color: kOnSurface),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: kOnSurface,
      displayColor: kOnSurface,
    ),
    iconTheme: const IconThemeData(color: kOnSurface),
  );
}
