import 'package:burn_engine/burn_engine.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// Net worth across the three bands, which is the one picture that says what a
/// plan actually looks like.
///
/// Three headline numbers per band say where a plan lands. They say nothing
/// about the shape of getting there: when the curve turns over, how wide the
/// three futures are, whether the pessimistic one runs out. The bands are the
/// substitute for a Monte Carlo (§13.1), so the spread between them is the
/// closest thing this app has to a confidence interval and it deserves to be
/// seen rather than summarised.
class NetWorthChart extends StatelessWidget {
  final Band<BandResult> bands;

  /// Height of the plot. Wide windows can afford more.
  final double height;

  const NetWorthChart({super.key, required this.bands, this.height = 260});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final series = <(String, List<ProjectedYear>, Color)>[
      ('Optimistic', bands.optimistic.finalPass.years, scheme.tertiary),
      ('Expected', bands.expected.finalPass.years, scheme.primary),
      ('Pessimistic', bands.pessimistic.finalPass.years, scheme.error),
    ];
    if (series.every((s) => s.$2.isEmpty)) return const SizedBox.shrink();

    double dollars(ProjectedYear y) => y.netWorth.netWorth.dollars;
    final all = series.expand((s) => s.$2).toList();
    final firstYear = all.map((y) => y.year).reduce((a, b) => a < b ? a : b);
    final lastYear = all.map((y) => y.year).reduce((a, b) => a > b ? a : b);
    final peak = all.map(dollars).reduce((a, b) => a > b ? a : b);
    final floor = all.map(dollars).reduce((a, b) => a < b ? a : b);

    // Rounded outward so the axis reads in whole millions rather than in
    // whatever the peak happened to be.
    final top = peak <= 0 ? 1.0 : _roundOut(peak);
    final bottom = floor < 0 ? -_roundOut(-floor) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          children: [
            for (final (label, _, colour) in series)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 12, height: 3, color: colour),
                  const SizedBox(width: 6),
                  Text(label, style: theme.textTheme.bodySmall),
                ],
              ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: height,
          child: LineChart(
            LineChartData(
              minX: firstYear.toDouble(),
              maxX: lastYear.toDouble(),
              minY: bottom,
              maxY: top,
              clipData: const FlClipData.all(),
              gridData: FlGridData(
                drawVerticalLine: false,
                horizontalInterval: (top - bottom) / 4,
                getDrawingHorizontalLine: (_) => FlLine(
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 52,
                    interval: (top - bottom) / 4,
                    getTitlesWidget: (value, meta) => Text(
                      _short(value),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    interval: _yearStep(lastYear - firstYear),
                    getTitlesWidget: (value, meta) => Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '${value.round()}',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => [
                    for (final spot in spots)
                      LineTooltipItem(
                        '${series[spot.barIndex].$1}  ${_short(spot.y)}',
                        theme.textTheme.bodySmall!
                            .copyWith(color: series[spot.barIndex].$3),
                      ),
                  ],
                ),
              ),
              lineBarsData: [
                for (final (_, years, colour) in series)
                  LineChartBarData(
                    spots: [
                      for (final y in years)
                        FlSpot(y.year.toDouble(), dollars(y)),
                    ],
                    color: colour,
                    barWidth: 2,
                    isCurved: false,
                    dotData: const FlDotData(show: false),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'In today\'s money, so a flat line is holding its value rather than '
          'standing still. Each line retires in its own year and spends from '
          'then on, so a worse market keeps working and can climb above a '
          'better one that stopped years earlier. Two lines meeting does not '
          'mean either could retire then.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// A year label every five or ten years, so a forty-year plan does not print
  /// forty of them.
  static double _yearStep(int span) => span > 30
      ? 10
      : span > 12
          ? 5
          : 2;

  static double _roundOut(double v) {
    final magnitude = <double>[1e6, 1e5, 1e4, 1e3]
        .firstWhere((m) => v >= m, orElse: () => 100);
    return (v / magnitude).ceil() * magnitude;
  }

  static String _short(double dollars) {
    final sign = dollars < 0 ? '-' : '';
    final v = dollars.abs();
    if (v >= 1e6) return '$sign\$${(v / 1e6).toStringAsFixed(1)}M';
    if (v >= 1e3) return '$sign\$${(v / 1e3).round()}K';
    return '$sign\$${v.round()}';
  }
}
