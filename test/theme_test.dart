import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slow_burn/theme/app_theme.dart';

/// WCAG relative luminance.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

double contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final light = math.max(la, lb);
  final dark = math.min(la, lb);
  return (light + 0.05) / (dark + 0.05);
}

void main() {
  group('the palette FF7467 generates', () {
    // The implementation plan flagged this: FF7467 is a coral where Roamfree's
    // FFC067 is an amber, and a darker seed. Worth checking before seven
    // screens are built on it rather than after.
    for (final (name, theme) in [
      ('light', lightTheme()),
      ('dark', darkTheme()),
    ]) {
      test('$name: text on every surface clears 4.5:1', () {
        final s = theme.colorScheme;
        final pairs = <String, (Color, Color)>{
          'onSurface / surface': (s.onSurface, s.surface),
          'onSurfaceVariant / surfaceContainerLow': (
            s.onSurfaceVariant,
            s.surfaceContainerLow,
          ),
          'onPrimaryContainer / primaryContainer': (
            s.onPrimaryContainer,
            s.primaryContainer,
          ),
          'onSecondaryContainer / secondaryContainer': (
            s.onSecondaryContainer,
            s.secondaryContainer,
          ),
          'onError / error': (s.onError, s.error),
        };
        pairs.forEach((label, pair) {
          expect(contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5),
              reason: '$name $label');
        });
      });

      test('$name: onPrimary clears 3:1 against primary', () {
        // A button label is large and non-body text, so 3:1 is the bar.
        final s = theme.colorScheme;
        expect(contrast(s.onPrimary, s.primary), greaterThanOrEqualTo(3.0),
            reason: '$name onPrimary / primary');
      });
    }

    test('one seed drives both brightnesses', () {
      expect(seedColor, const Color(0xFFFF7467));
      expect(lightTheme().colorScheme.brightness, Brightness.light);
      expect(darkTheme().colorScheme.brightness, Brightness.dark);
    });

    test('a card adds no margin of its own, as in Roamfree', () {
      expect(lightTheme().cardTheme.margin, EdgeInsets.zero);
    });
  });
}
