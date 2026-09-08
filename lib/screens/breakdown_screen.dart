import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../widgets/fields.dart';
import '../widgets/variant_picker.dart';

/// The plan as three questions, in the order somebody actually asks them.
///
/// The Plan screen answers "what does the engine say" and then lists every
/// lever underneath it. That is the right shape for checking a projection and
/// the wrong one for thinking about your own affairs, where the questions run:
/// what will I be spending, what do I need to own to pay for that safely, and
/// how long until I own it. Each of those has one answer and a small number of
/// things that move it, and they belong together rather than in one pile at
/// the bottom.
class BreakdownScreen extends ConsumerWidget {
  const BreakdownScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final projection = ref.watch(projectionProvider);

    return projection.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('$e', style: theme.textTheme.bodyMedium),
        ),
      ),
      data: (bands) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Your plan, in three questions',
              style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Everything is in today\'s money, so none of these numbers needs '
            'an inflation guess applied to it.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          _Spending(bands: bands),
          const SizedBox(height: 32),
          _SafeAssets(bands: bands),
          const SizedBox(height: 32),
          _HowLong(bands: bands),
        ],
      ),
    );
  }
}

/// The frame each question shares: what is asked, what the answer is, why, and
/// what moves it.
class _Question extends StatelessWidget {
  final int number;
  final String question;
  final String? answer;
  final String? unavailable;
  final String unit;
  final String because;
  final List<Widget> levers;

  const _Question({
    required this.number,
    required this.question,
    required this.because,
    required this.levers,
    this.answer,
    this.unavailable,
    this.unit = '',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text('$number',
                  style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(question, style: theme.textTheme.titleLarge),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (answer != null)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(answer!,
                          style: theme.textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.primary)),
                      if (unit.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(unit,
                            style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ],
                  )
                else
                  Text(unavailable ?? '—',
                      style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                Text(because,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                if (levers.isNotEmpty) ...[
                  const Divider(height: 32),
                  ...levers,
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Question one. What retirement costs, which everything else is measured
/// against.
class _Spending extends ConsumerWidget {
  final Band<BandResult> bands;
  const _Spending({required this.bands});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final household = ref.watch(householdProvider);
    final result = bands.expected;
    final level = result.levelEquivalentRetirementExpenses;
    final firstYear = result.retirementAnnualExpenses;

    final notLevel = level != null &&
        firstYear != null &&
        (level.dollars - firstYear.dollars).abs() > 500;

    return _Question(
      number: 1,
      question: 'What will I be spending in retirement?',
      answer: level == null ? null : formatMoney(level),
      unavailable: 'Not enough entered yet to say.',
      unit: 'a year',
      because: level == null
          ? 'Spending is what sizes the whole plan, so nothing below can be '
              'answered until it is entered.'
          : notLevel
              ? 'The first year of retirement costs '
                  '${formatMoney(firstYear!)}, but spending does not stay '
                  'level: a mortgage ends, travel tails off. This is the flat '
                  'amount worth the same as the whole stream, and it is what '
                  'the plan is sized on.'
              : 'Your spending after retirement, held flat across the whole '
                  'of it. This is what the plan is sized on.',
      levers: [
        if (_healthAtRetirement(result) case final health?) ...[
          _Aside(
            label: 'Health coverage, which the plan works out for itself',
            value: '${formatMoney(health.net)} a year',
            note: health.credit.isPositive
                ? 'A ${formatMoney(health.gross)} benchmark policy less a '
                    '${formatMoney(health.credit)} subsidy, priced from your '
                    'income and household size in that year. Do not add it as '
                    'a spending line, or it will be counted twice.'
                : 'A ${formatMoney(health.gross)} benchmark policy with no '
                    'subsidy at this income. Do not add it as a spending '
                    'line, or it will be counted twice.',
          ),
          const Divider(height: 32),
        ],
        // The thing that reads as a broken calculator: adding a large cost
        // that ends before retirement leaves this number untouched, because
        // it is not part of what retirement costs. It moves the date instead,
        // and nothing said so.
        if (_endingBefore(household, result) case final ending?) ...[
          _Aside(
            label: 'Spending that ends before you retire',
            value: formatMoney(ending),
            note: 'College, daycare, a car loan. None of it is part of what '
                'retirement costs, so it does not change the figure above. It '
                'moves the date in question three instead.',
          ),
          const Divider(height: 32),
        ],
        Text('What moves it', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(
          'Every line on the Spending screen, with whatever you said each one '
          'does at retirement. Housing is on its own screen, since a plan has '
          'to have somewhere to live in every year of it.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => showVariantPicker(context, ref),
            icon: const Icon(Icons.auto_awesome_outlined),
            label: const Text('Shape it: lean, barista, coast, fat'),
          ),
        ),
      ],
    );
  }

  /// What buying your own cover costs in the first retired year, and what the
  /// subsidy takes off it. Zero where an employer is still paying.
  static ({Money gross, Money credit, Money net})? _healthAtRetirement(
      BandResult result) {
    final year = result.retirementYear;
    if (year == null) return null;
    final retired =
        result.finalPass.years.where((y) => y.year == year).firstOrNull;
    if (retired == null) return null;
    final gross =
        sumMoney(retired.solved.owed.map((o) => o.health.benchmarkPremium));
    if (!gross.isPositive) return null;
    final credit =
        sumMoney(retired.solved.owed.map((o) => o.health.premiumTaxCredit));
    return (gross: gross, credit: credit, net: gross - credit);
  }

  /// Everything the household spends that is over before retirement begins.
  ///
  /// Null where there is none, or where no retirement year is solved yet.
  static Money? _endingBefore(Household household, BandResult result) {
    final year = result.retirementYear;
    if (year == null) return null;
    var total = Money.zero;
    for (final item in household.expenseItems) {
      final ends = item.endYear;
      if (ends == null || ends >= year) continue;
      final from = item.startYear ?? DateTime.now().year;
      final years = ends - from + 1;
      if (years > 0) total += item.amount * years;
    }
    return total.isPositive ? total : null;
  }

}

/// Question two. What has to be owned, in things that are not going to halve.
class _SafeAssets extends ConsumerWidget {
  final Band<BandResult> bands;
  const _SafeAssets({required this.bands});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scenario = ref.watch(scenarioProvider);
    final household = ref.watch(householdProvider);
    final classes = ref.watch(assetClassesProvider);
    final notifier = ref.read(scenarioProvider.notifier);

    final result = bands.expected;
    final level = result.levelEquivalentRetirementExpenses;
    final fire = result.fireNumber;
    final safe = _safeReturn(household, classes);
    final years = _retirementLength(household, scenario.assumptions, result);

    final forever = level == null || safe <= 0
        ? null
        : Money.dollars(level.dollars / safe);
    final untilDeath = level == null || years == null
        ? null
        : Money.dollars(level.dollars * annuityFactor(safe, years));

    return _Question(
      number: 2,
      question: 'What do I need to own to pay for that?',
      answer: fire == null ? null : formatMoney(fire),
      unavailable: 'Answered once there is a spending figure above.',
      unit: 'invested',
      because: fire == null
          ? 'This is your spending divided by what you can safely draw from '
              'it each year.'
          : 'Your spending divided by a '
              '${formatPercent(scenario.assumptions.safeWithdrawalRate)} '
              'withdrawal rate, so the capital is never spent down. Tax is '
              'handled on the other side of the comparison: what you hold is '
              'measured after the tax of turning it into money, rather than '
              'this figure being grossed up.',
      levers: [
        Text('Three ways of asking it', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Two things separate these: the rate the money earns, and whether '
          'the capital is ever spent. A lower rate needs more, and spending '
          'the capital needs less. The headline is smallest because it uses '
          'the highest rate, not because it is the least cautious.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        _Comparison(rows: [
          (
            what: 'Never spend the capital',
            rate: scenario.assumptions.safeWithdrawalRate,
            why: 'your withdrawal rate',
            amount: fire,
            headline: true,
          ),
          (
            what: 'Never spend the capital',
            rate: safe,
            why: 'what you will hold',
            amount: forever,
            headline: false,
          ),
          (
            what: years == null
                ? 'Spend it to zero by the end'
                : 'Spend it to zero over $years years',
            rate: safe,
            why: 'what you will hold',
            amount: untilDeath,
            headline: false,
          ),
        ]),
        const SizedBox(height: 12),
        Text(
          'None of the three counts Social Security, a pension, or any other '
          'income you will have in retirement. They ask what the pot alone '
          'has to cover. Money arriving later makes the date in question '
          'three earlier without making the target smaller.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const Divider(height: 32),
        Text('What moves it', style: theme.textTheme.titleSmall),
        const SizedBox(height: 12),
        FieldRow([
          PercentField(
            key: ValueKey(scenario.assumptions.safeWithdrawalRate),
            label: 'Safe withdrawal rate',
            helper: 'The share you draw in the first year of retirement.',
            initial: scenario.assumptions.safeWithdrawalRate,
            onChanged: (v) => notifier.replace(Scenario(
              id: scenario.id,
              householdId: scenario.householdId,
              label: scenario.label,
              assumptions: _withRate(scenario.assumptions, v),
            )),
          ),
        ]),
        const SizedBox(height: 8),
        for (final cls in classes.where((c) => _heldInRetirement(household, c)))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FieldRow([
              PercentField(
                key: ValueKey('${cls.id}${cls.expectedRealReturn}'),
                label: '${assetClassName(cls)}, above inflation',
                initial: cls.expectedRealReturn,
                onChanged: (v) =>
                    ref.read(assetClassesProvider.notifier).replace([
                  for (final c in classes)
                    if (c.id == cls.id)
                      AssetClass(
                        id: c.id,
                        label: c.label,
                        expectedRealReturn: v,
                        pessimisticRealReturn: c.pessimisticRealReturn,
                        optimisticRealReturn: c.optimisticRealReturn,
                        incomeYield: c.incomeYield,
                        qualifiedIncomeFraction: c.qualifiedIncomeFraction,
                      )
                    else
                      c,
                ]),
              ),
            ]),
          ),
        const SizedBox(height: 4),
        // The rate above is a blend of this, so it belongs beside it rather
        // than on another screen with a note pointing at it.
        _RetirementHolding(household: household, classes: classes),
      ],
    );
  }

  /// The blended real return of whatever the household ends up holding, which
  /// is the rate a safe-asset answer has to be built on.
  static Rate _safeReturn(Household household, List<AssetClass> classes) {
    final byId = {for (final c in classes) c.id: c};
    var weight = Money.zero;
    var total = 0.0;
    for (final account in household.accounts) {
      final cls = byId[account.allocationIn(retired: true)];
      if (cls == null || !account.balance.isPositive) continue;
      weight += account.balance;
      total += cls.expectedRealReturn * account.balance.dollars;
    }
    if (!weight.isPositive) {
      // Nothing held yet, so answer on what a new account would be given.
      final bonds =
          classes.where((c) => c.label == AssetClassLabel.bonds).firstOrNull;
      return bonds?.expectedRealReturn ?? 0;
    }
    return total / weight.dollars;
  }

  static bool _heldInRetirement(Household household, AssetClass cls) =>
      household.accounts
          .any((a) => a.allocationIn(retired: true) == cls.id) ||
      cls.label == AssetClassLabel.bonds;

  static int? _retirementLength(
      Household household, Assumptions assumptions, BandResult result) {
    final year = result.retirementYear;
    if (year == null) return null;
    final end = horizonYear(household, assumptions, DateTime.now().year);
    final years = end - year + 1;
    return years > 0 ? years : null;
  }
}

/// Question three. When, and what the taxman takes on the way.
class _HowLong extends ConsumerWidget {
  final Band<BandResult> bands;
  const _HowLong({required this.bands});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final classes = ref.watch(assetClassesProvider);
    final result = bands.expected;
    final year = result.retirementYear;
    final now = DateTime.now().year;

    final retired = year == null
        ? null
        : result.finalPass.years.where((y) => y.year == year).firstOrNull;
    final liquid = retired?.netWorth.liquidNetWorth;
    final afterTax = retired?.netWorth.afterTaxLiquidNetWorth;
    final taxToSell =
        liquid == null || afterTax == null ? null : liquid - afterTax;

    return _Question(
      number: 3,
      question: 'How long until I own it?',
      answer: year == null ? null : '$year',
      unavailable: 'Not within the plan, on these numbers.',
      unit: year == null ? '' : 'in ${year - now} years',
      because: year == null
          ? 'The pot never reaches the figure above before the plan runs out. '
              'Spending less, earning more, or a longer horizon are what '
              'change that.'
          : 'The first year that passes three tests: the pot clears question '
              'two after the tax of liquidating it, the years before 59½ are '
              'funded from money you can actually reach, and a full '
              'projection of every remaining year survives to the end. That '
              'last one is where Social Security, a pension and the tax on '
              'each year of drawing down are counted.',
      levers: [
        if (taxToSell != null && taxToSell.isPositive) ...[
          _Aside(
            label: 'Tax owed to turn it into money to spend',
            value: formatMoney(taxToSell),
            note: 'What selling everything liquid in $year would cost in '
                'capital gains and income tax. Already counted in the answer '
                'above, and worth seeing on its own.',
          ),
          const Divider(height: 32),
        ],
        Text('What moves it', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'What your investments earn between now and then, which is the '
          'lever with the longest arm on this answer.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        for (final cls in classes)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FieldRow([
              PercentField(
                key: ValueKey('grow${cls.id}${cls.expectedRealReturn}'),
                label: '${assetClassName(cls)}, above inflation',
                initial: cls.expectedRealReturn,
                onChanged: (v) =>
                    ref.read(assetClassesProvider.notifier).replace([
                  for (final c in classes)
                    if (c.id == cls.id)
                      AssetClass(
                        id: c.id,
                        label: c.label,
                        expectedRealReturn: v,
                        pessimisticRealReturn: c.pessimisticRealReturn,
                        optimisticRealReturn: c.optimisticRealReturn,
                        incomeYield: c.incomeYield,
                        qualifiedIncomeFraction: c.qualifiedIncomeFraction,
                      )
                    else
                      c,
                ]),
              ),
            ]),
          ),
        const SizedBox(height: 4),
        Text(
          'A worse decade and a better one are the pessimistic and optimistic '
          'bands on the Plan screen. This answer is the middle one.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// A secondary figure under a headline: smaller, and saying what it is.
class _Aside extends StatelessWidget {
  final String label;
  final String value;
  final String note;

  const _Aside({required this.label, required this.value, required this.note});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.bodyMedium),
              Text(note,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Text(value,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

Assumptions _withRate(Assumptions a, Rate rate) => Assumptions(
      generalInflationRate: a.generalInflationRate,
      safeWithdrawalRate: rate,
      contributionWaterfall: a.contributionWaterfall,
      withdrawalOrder: a.withdrawalOrder,
      highInterestDebtThresholdRate: a.highInterestDebtThresholdRate,
      includeSocialSecurity: a.includeSocialSecurity,
      capitalGainsRealizationRate: a.capitalGainsRealizationRate,
      projectionHorizonAge: a.projectionHorizonAge,
      acaMagiCeilingPercentOfFpl: a.acaMagiCeilingPercentOfFpl,
      pmiTerminationLtv: a.pmiTerminationLtv,
      assetSaleCostRate: a.assetSaleCostRate,
      assetAppreciationByCategory: a.assetAppreciationByCategory,
      taxYearId: a.taxYearId,
    );

/// The three answers side by side, since the only way the ordering makes sense
/// is seeing the rate next to each one.
class _Comparison extends StatelessWidget {
  final List<
      ({
        String what,
        Rate rate,
        String why,
        Money? amount,
        bool headline,
      })> rows;

  const _Comparison({required this.rows});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.what,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight:
                                row.headline ? FontWeight.w600 : null),
                      ),
                      Text(
                        'at ${formatPercent(row.rate)}, ${row.why}'
                        '${row.headline ? ' · the figure above' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  row.amount == null ? '—' : formatMoney(row.amount!),
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: row.headline ? FontWeight.w700 : null,
                      color: row.headline ? theme.colorScheme.primary : null),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// What everything moves into at retirement, which is what sets the rate the
/// two safe-asset answers are built on.
class _RetirementHolding extends ConsumerWidget {
  final Household household;
  final List<AssetClass> classes;

  const _RetirementHolding({required this.household, required this.classes});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifier = ref.read(householdProvider.notifier);
    final movable = household.accounts.where((a) => !a.kind.isCash).toList();
    if (movable.isEmpty) {
      return Text(
        'Once there are accounts here, this is where you say what they move '
        'into at retirement.',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }

    final ids = movable.map((a) => a.retirementAllocationId).toSet();
    final shared = ids.length == 1 ? ids.single : null;
    final mixed = ids.length > 1;

    return SearchableField<AssetClass>(
      key: ValueKey('retire$shared$mixed'),
      label: 'What you move into at retirement',
      helper: mixed
          ? 'Your accounts differ. Choosing here sets all '
              '${movable.length} of them.'
          : 'Sets all ${movable.length} of your invested accounts, and with '
              'them the rate the two figures above use. Cash stays put.',
      values: classes,
      value: classes.where((c) => c.id == shared).firstOrNull,
      noneLabel: mixed ? 'Mixed' : 'Leave everything where it is',
      describe: assetClassName,
      onChanged: (c) {
        for (final account in movable) {
          notifier.saveAccount(account.withRetirementAllocation(c?.id));
        }
      },
    );
  }
}
