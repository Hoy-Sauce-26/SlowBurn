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
  group('the palette the seed generates', () {
    // Checked whenever the seed moves. A palette is generated, so a new seed
    // is a new set of contrast pairs and not just a new hue.
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
      expect(seedColor, const Color(0xFF67A6FF));
      expect(lightTheme().colorScheme.brightness, Brightness.light);
      expect(darkTheme().colorScheme.brightness, Brightness.dark);
    });

    test('a card adds no margin of its own, as in Roamfree', () {
      expect(lightTheme().cardTheme.margin, EdgeInsets.zero);
    });
  });

  group('selection does not read as a warning', () {
    test('the primary sits far from the error colour', () {
      // A coral seed put filled buttons, selected chips and focused fields
      // close enough to the error red that every selection looked like a
      // problem. Distance in hue is what stops that.
      for (final theme in [lightTheme(), darkTheme()]) {
        final s = theme.colorScheme;
        final primaryHue = HSLColor.fromColor(s.primary).hue;
        final errorHue = HSLColor.fromColor(s.error).hue;
        final gap = (primaryHue - errorHue).abs();
        final separation = gap > 180 ? 360 - gap : gap;
        expect(separation, greaterThan(60),
            reason: 'primary and error should not be mistaken for each other');
      }
    });
  });
}
