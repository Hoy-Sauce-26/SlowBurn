import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../widgets/fields.dart';
import '../widgets/entity_list.dart';
import 'property_screen.dart';
import 'spending_screen.dart';

/// Where the household lives, for the whole of the plan rather than for today.
///
/// Housing is the one cost that is never optional and the easiest to lose:
/// selling a home is a single field, and the fourteen years afterwards go
/// unpriced unless something else fills them. A list of assets cannot show
/// that, and a per-year flag says it far too late. A timeline shows it at a
/// glance, which is why it is a screen of its own.
class HousingScreen extends ConsumerWidget {
  const HousingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final household = ref.watch(householdProvider);
    return EntityList(
      title: 'Where you live',
      blurb: 'Every year of the plan, and what is keeping a roof on in each '
          'of them.',
      addLabel: 'I rent',
      emptyMessage: household.people.isEmpty
          ? 'Add somebody to the household first.'
          : '',
      onAdd: () =>
          askAboutRent(context, ref, from: DateTime.now().year),
      children: const [HousingTimeline()],
    );
  }
}

/// The timeline itself, laid out as a plain column so it works inside the
/// screen above and inside the setup flow, which is a scroll view of its own.
class HousingTimeline extends ConsumerWidget {
  const HousingTimeline({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final household = ref.watch(householdProvider);
    final assumptions = ref.watch(scenarioProvider).assumptions;
    final thisYear = DateTime.now().year;
    final end = household.people.isEmpty
        ? thisYear
        : horizonYear(household, assumptions, thisYear);

    final spans = household.people.isEmpty
        ? <HousingSpan>[]
        : housingTimeline(household, fromYear: thisYear, toYear: end);
    final gaps = spans.where((s) => s.isGap).toList();
    final misfiled = looksLikeHousing(household);
    final bills = looksLikeSupport(household);

    if (spans.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
          if (gaps.isEmpty)
            const _Verdict(
              icon: Icons.check_circle_outline,
              text: 'Every year of this plan has somewhere to live in it.',
              good: true,
            )
          else
            _Verdict(
              icon: Icons.report_problem_outlined,
              good: false,
              text: gaps.length == 1
                  ? 'From ${gaps.single.fromYear} to ${gaps.single.toYear} the '
                      'plan has you living for free, which will make it look '
                      'better than it is.'
                  : '${gaps.length} stretches of this plan have you living '
                      'for free, which will make it look better than it is.',
            ),
          const SizedBox(height: 16),
          for (final span in spans)
            _Span(
              span: span,
              onFill: span.isGap
                  ? () => askAboutRent(context, ref, from: span.fromYear)
                  : null,
              onBuy: span.isGap
                  ? () => const PropertyScreen().editAsset(context, ref, null)
                  : null,
              onEdit: (cover) => _edit(context, ref, cover),
              onEditCost: (item) =>
                  const SpendingScreen().editExpense(context, ref, item),
              costsFor: (homeId) => household.expenseItems
                  .where((i) => i.housingId == homeId)
                  .toList(),
            ),
          const SizedBox(height: 24),
          if (bills.isNotEmpty) ...[
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bills.length == 1
                          ? 'A bill is filed as somewhere to live'
                          : '${bills.length} bills are filed as somewhere to '
                              'live',
                      style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Anything under "Rent or lodging" counts as a roof, so '
                      'these are housing you for as long as you pay them. '
                      'Move them to "Housing costs" and they stay in the plan '
                      'as spending without pretending to be shelter.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer),
                    ),
                    const SizedBox(height: 8),
                    for (final item in bills)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => ref
                              .read(householdProvider.notifier)
                              .saveExpenseItem(refiled(item, household, ref,
                                  into: MetaCategory.housingSupport)),
                          child: Text(
                              'Move "${item.label}" to Housing costs'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (misfiled.isNotEmpty) ...[
            Card(
              color: theme.colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      misfiled.length == 1
                          ? 'One spending line reads like housing and is filed '
                              'somewhere else'
                          : '${misfiled.length} spending lines read like '
                              'housing and are filed somewhere else',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Only the Housing category counts toward a roof, so '
                      'these are being spent without housing anybody.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer),
                    ),
                    const SizedBox(height: 8),
                    for (final item in misfiled)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => ref
                              .read(householdProvider.notifier)
                              .saveExpenseItem(refiled(item, household, ref)),
                          child:
                              Text('File "${item.label}" under Housing'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Text('What counts', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'A home you own, for the years you own it. Owning outright counts, '
            'the cost of that being the tax and insurance a paid-off mortgage '
            'carries on charging.\n\n'
            'Any spending line filed under "Rent or lodging", for the years '
            'it runs. That is the only category this looks at.\n\n'
            'Utilities, internet, property tax, HOA dues and contents '
            'insurance belong under "Housing costs" instead. They are real '
            'spending and they house nobody, so paying an electricity bill '
            'for forty years does not put a roof over anything.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => const SpendingScreen().editExpense(
                context, ref, null,
                startingAt: MetaCategory.housing),
            icon: const Icon(Icons.add),
            label: const Text('Add rent or lodging'),
          ),
        ),
      ],
    );
  }
}

/// Opens whatever is covering a span, wherever it happens to live.
void _edit(BuildContext context, WidgetRef ref, HousingCover cover) {
  final household = ref.read(householdProvider);
  if (cover.owned) {
    final asset = household.assets.where((a) => a.id == cover.id).firstOrNull;
    if (asset != null) const PropertyScreen().editAsset(context, ref, asset);
    return;
  }
  final item =
      household.expenseItems.where((i) => i.id == cover.id).firstOrNull;
  if (item != null) const SpendingScreen().editExpense(context, ref, item);
}

class _Verdict extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool good;

  const _Verdict({required this.icon, required this.text, required this.good});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      color: good ? scheme.surfaceContainerHighest : scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon,
                color: good ? scheme.onSurfaceVariant : scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: good
                        ? scheme.onSurfaceVariant
                        : scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One stretch of the timeline: the years, and what is holding them up.
class _Span extends StatelessWidget {
  final HousingSpan span;
  final VoidCallback? onFill;
  final VoidCallback? onBuy;
  final void Function(HousingCover)? onEdit;
  final void Function(ExpenseItem)? onEditCost;
  final List<ExpenseItem> Function(Id) costsFor;

  const _Span({
    required this.span,
    required this.costsFor,
    this.onFill,
    this.onBuy,
    this.onEdit,
    this.onEditCost,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final years = span.fromYear == span.toYear
        ? '${span.fromYear}'
        : '${span.fromYear} to ${span.toYear}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The bar is the point: a gap is a hole you can see from across the
          // room, which a row of text is not.
          Container(
            width: 6,
            height: span.years <= 1 ? 44.0 : (44.0 + span.years * 1.5)
                .clamp(44.0, 140.0),
            decoration: BoxDecoration(
              color: span.isGap ? scheme.error : scheme.primary,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$years  ·  ${span.years} '
                    '${span.years == 1 ? 'year' : 'years'}',
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                if (span.isGap)
                  Text('Nothing is paying for anywhere to live',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.error))
                else
                  // Named and tappable, because the first question about a
                  // span is what is holding it up and the second is how to
                  // change it.
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final cover in span.covers) ...[
                        ActionChip(
                          avatar: Icon(
                              cover.owned
                                  ? Icons.home_outlined
                                  : Icons.vpn_key_outlined,
                              size: 16),
                          label: Text(cover.label),
                          onPressed: () => onEdit?.call(cover),
                        ),
                        // The bills that come with that roof, shown beside it
                        // rather than in a list somewhere else.
                        for (final cost in costsFor(cover.id))
                          ActionChip(
                            avatar: const Icon(Icons.receipt_outlined,
                                size: 16),
                            label: Text(cost.label),
                            onPressed: () => onEditCost?.call(cost),
                          ),
                      ],
                    ],
                  ),
                if (span.isGap) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: onFill,
                        child: Text('Rent from ${span.fromYear}'),
                      ),
                      TextButton(
                        onPressed: onBuy,
                        child: const Text('Buy somewhere'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Spending that reads like a roof and is filed under something else.
///
/// The check is a category, deliberately: guessing from labels is how a plan
/// ends up counting "rental income" as somewhere to live. But a line called
/// Rent sitting under Misc is somebody who meant it, so it is offered rather
/// than silently ignored.
List<ExpenseItem> looksLikeHousing(Household household) {
  final housing = household.expenseCategories
      .where((c) => c.metaCategory == MetaCategory.housing)
      .map((c) => c.id)
      .toSet();
  const words = ['rent', 'lodging', 'lease', 'apartment', 'flat'];
  return household.expenseItems
      .where((i) =>
          !housing.contains(i.categoryId) &&
          words.any((w) => i.label.toLowerCase().contains(w)))
      .toList();
}

/// Bills filed as shelter, which is the mistake that houses a plan for free.
///
/// The opposite of [looksLikeHousing] and the more dangerous of the two: a
/// misfiled rent shows a gap somebody can see, while a misfiled electricity
/// bill quietly reports a roof that is not there.
List<ExpenseItem> looksLikeSupport(Household household) {
  final housing = household.expenseCategories
      .where((c) => c.metaCategory == MetaCategory.housing)
      .map((c) => c.id)
      .toSet();
  const words = [
    'electric', 'gas', 'water', 'utilit', 'internet', 'broadband', 'wifi',
    'hoa', 'insurance', 'property tax', 'council tax', 'upkeep',
    'maintenance', 'repair', 'bill',
  ];
  return household.expenseItems
      .where((i) =>
          housing.contains(i.categoryId) &&
          words.any((w) => i.label.toLowerCase().contains(w)))
      .toList();
}

/// The same line, filed under Housing, creating that category if this
/// household has never had one.
ExpenseItem refiled(
  ExpenseItem item,
  Household household,
  WidgetRef ref, {
  MetaCategory into = MetaCategory.housing,
}) {
  final notifier = ref.read(householdProvider.notifier);
  final category = household.expenseCategories
          .where((c) => c.metaCategory == into)
          .firstOrNull ??
      ExpenseCategory(
        id: newId('cat'),
        householdId: household.id,
        label: metaCategoryName(into),
        metaCategory: into,
      );
  notifier.saveCategory(category);
  return ExpenseItem(
    id: item.id,
    categoryId: category.id,
    label: item.label,
    amount: item.amount,
    frequency: item.frequency,
    startYear: item.startYear,
    endYear: item.endYear,
    startMonth: item.startMonth,
    endMonth: item.endMonth,
    relativeInflationRate: item.relativeInflationRate,
    phase: item.phase,
    postRetirementAmount: item.postRetirementAmount,
  );
}
