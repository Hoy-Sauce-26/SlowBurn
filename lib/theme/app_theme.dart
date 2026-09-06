import 'package:flutter/material.dart';

/// The one seed both brightnesses are generated from.
///
/// Roamfree's amber (`FFC067`) with Slow Burn's coral in its place. Material 3
/// derives the whole palette from this, so it is the only colour literal the
/// app should contain.
const seedColor = Color(0xFFFF7467);

ThemeData lightTheme() => _theme(Brightness.light);
ThemeData darkTheme() => _theme(Brightness.dark);

ThemeData _theme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    // Roamfree's card rhythm: the surrounding layout owns the spacing, so a
    // card never adds margin of its own.
    cardTheme: const CardThemeData(margin: EdgeInsets.zero),
  );
}
