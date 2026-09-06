import 'package:flutter/material.dart';

/// Roamfree's card, which is already the right shape for a FIRE number: an
/// icon, a large value, its unit, and what it is.
///
/// [value] carries the weight, so it stays legible when the number is long.
class MetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String unit;

  /// Shown in place of [value] where the engine could not produce one. A plan
  /// that never reaches its target says so, rather than showing a blank or an
  /// arbitrarily distant year (§8.2).
  final String? unavailable;

  const MetricCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.unit = '',
    this.unavailable,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missing = unavailable != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Column(
          children: [
            Icon(
              icon,
              color: missing
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.primary,
            ),
            const SizedBox(height: 8),
            Text(
              missing ? unavailable! : value,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: missing ? theme.colorScheme.onSurfaceVariant : null,
              ),
            ),
            if (unit.isNotEmpty && !missing)
              Text(
                unit,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            const SizedBox(height: 4),
            Text(label, style: theme.textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}
