import 'package:flutter/material.dart';

/// The one seed both brightnesses are generated from.
///
/// Material 3 derives the whole palette from this, so it is the only colour
/// literal the app should contain.
///
/// A coral was tried first and read as a warning: a selected chip, a filled
/// button and a focused field all sat close enough to the error red that every
/// selection looked like something had gone wrong. Blue carries no such
/// meaning, which matters in an app whose job is to show a household its own
/// mistakes without making the rest of the screen shout.
const seedColor = Color(0xFF67A6FF);

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
