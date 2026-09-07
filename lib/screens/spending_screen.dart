import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../services/flag_placement.dart';
import '../widgets/entity_list.dart';
import '../widgets/flag_banner.dart';
import '../widgets/fields.dart';

/// §3.7. What the household spends, and what changes at retirement.
///
/// `phase` and `postRetirementAmount` are the whole Lean-versus-Fat mechanism:
/// a car that stops, an apartment that starts, a travel line five times its
/// working figure. No single multiplier expresses that.
class SpendingScreen extends ConsumerWidget {
  const SpendingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final household = ref.watch(householdProvider);
    final notifier = ref.read(householdProvider.notifier);
    final categories = {for (final c in household.expenseCategories) c.id: c};

    // Grouped, because a flat list of thirty lines is a list nobody reads and
    // because the categories are what the plan actually reasons about.
    final byCategory = <MetaCategory, List<ExpenseItem>>{};
    for (final item in household.expenseItems) {
      final meta =
          categories[item.categoryId]?.metaCategory ?? MetaCategory.misc;
      byCategory.putIfAbsent(meta, () => []).add(item);
    }
    final ordered = MetaCategory.values.where(byCategory.containsKey);

    return EntityList(
      title: 'Spending',
      blurb: 'What the household spends now, and what changes at retirement.',
      addLabel: 'Add spending',
      emptyMessage:
          'Add what the household spends.\nLeave out mortgage payments, '
          'payroll deductions and health premiums: each reaches the plan '
          'through its own term already.',
      banner: const FlagBanner(home: FlagHome.spending),
      onAdd: () => editExpense(context, ref, null),
      children: [
        for (final meta in ordered)
          EntitySection(
            title: metaCategoryName(meta),
            blurb: _totalOf(byCategory[meta]!),
            addLabel: 'Add to ${metaCategoryName(meta).toLowerCase()}',
            onAdd: () => editExpense(context, ref, null, startingAt: meta),
            children: [
              // Housing costs belong to a particular roof, so they are shown
              // under it: a flat list of six bills says nothing about which
              // of them stop when the house is sold.
              if (meta == MetaCategory.housingSupport)
                for (final group in _byHome(byCategory[meta]!, household))
                  _HomeGroup(
                    title: group.title,
                    items: group.items,
                    describe: (i) => _describe(i, categories[i.categoryId]),
                    onTap: (i) => editExpense(context, ref, i),
                    onDelete: (i) => notifier.removeExpenseItem(i.id),
                  )
              else
                for (final item in byCategory[meta]!)
                  EntityTile(
                    icon: Icons.receipt_long_outlined,
                    title: item.label,
                    subtitle: _describe(item, categories[item.categoryId]),
                    trailing: formatMoneyCompact(item.amount),
                    onTap: () => editExpense(context, ref, item),
                    onDelete: () => notifier.removeExpenseItem(item.id),
                  ),
            ],
          ),
        const SizedBox(height: 8),
        EntitySection(
          title: 'One-off costs and windfalls',
          blurb: 'A new roof, a wedding, an inheritance. Anything that '
              'happens in one year rather than every year.',
          addLabel: 'Add a one-off',
          emptyMessage: 'Nothing planned.',
          onAdd: () => editEvent(context, ref, null),
          children: [
            for (final event in household.oneTimeEvents)
              EntityTile(
                icon: event.isOutflow
                    ? Icons.remove_circle_outline
                    : Icons.add_circle_outline,
                title: event.label,
                subtitle: '${humanise(event.kind.name)} · ${event.year}'
                    '${event.accountId == null ? '' : ' · from an account'}',
                trailing: formatMoneyCompact(
                    event.isOutflow ? -event.amount : event.amount),
                onTap: () => editEvent(context, ref, event),
                onDelete: () => notifier.removeOneTimeEvent(event.id),
              ),
          ],
        ),
      ],
    );
  }

  /// Housing costs gathered under the home each belongs to, with anything
  /// unattached last, since that is the group worth noticing.
  static List<({String title, List<ExpenseItem> items})> _byHome(
    List<ExpenseItem> items,
    Household household,
  ) {
    final homes = {for (final h in homesIn(household)) h.id: h};
    final grouped = <String, List<ExpenseItem>>{};
    for (final item in items) {
      final home = homes[item.housingId];
      grouped.putIfAbsent(home?.label ?? '', () => []).add(item);
    }
    final named = grouped.keys.where((k) => k.isNotEmpty).toList()..sort();
    return [
      for (final title in named) (title: title, items: grouped[title]!),
      if (grouped.containsKey(''))
        (title: 'Not tied to a home', items: grouped['']!),
    ];
  }

  static String _totalOf(List<ExpenseItem> items) {
    final total = sumMoney(items.map((i) => i.amount));
    return '${formatMoney(total)} a year';
  }

  /// §3.8. A single dated inflow or outflow: an inheritance, a roof, a truck.
  ///
  /// An outflow must say where the money comes from, since where the $40,000
  /// for a truck comes from changes the projection materially and only the
  /// user knows.
  Future<void> editEvent(
      BuildContext context, WidgetRef ref, OneTimeEvent? existing) async {
    final household = ref.read(householdProvider);
    final notifier = ref.read(householdProvider.notifier);

    var label = existing?.label ?? '';
    var kind = existing?.kind ?? OneTimeEventKind.majorRepair;
    var year = existing?.year ?? DateTime.now().year + 1;
    var outflow = existing == null ? true : existing.isOutflow;
    var amount = existing == null
        ? Money.zero
        : (existing.isOutflow ? -existing.amount : existing.amount);
    // An outflow must name its source (invariant 16), so it starts on one
    // rather than on nothing the user has to notice is missing.
    var accountId = existing?.accountId ??
        (household.accounts.isEmpty ? null : household.accounts.first.id);
    var treatment = existing?.taxTreatment ?? EventTaxTreatment.nonTaxable;

    await showEditor<void>(
      context,
      title: existing == null ? 'Add a one-off' : existing.label,
      build: (context) => StatefulBuilder(
        builder: (context, setState) => Column(
          children: [
            FieldRow([
              EnumField<OneTimeEventKind>(
                label: 'Kind',
                values: OneTimeEventKind.values,
                value: kind,
                onChanged: (v) => setState(() => kind = v),
              ),
              YearField(
                label: 'Year',
                initial: year,
                onChanged: (v) => year = v ?? year,
              ),
            ]),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Money out')),
                ButtonSegment(value: false, label: Text('Money in')),
              ],
              selected: {outflow},
              onSelectionChanged: (s) => setState(() => outflow = s.first),
            ),
            const SizedBox(height: 12),
            FieldRow([
              MoneyField(
                label: 'Amount',
                initial: amount,
                onChanged: (v) => amount = v,
              ),
              if (household.accounts.isNotEmpty)
                ChoiceField<Account?>(
                  label: outflow ? 'Paid from' : 'Lands in',
                  helper: outflow
                      ? 'Required: where it comes from changes the plan'
                      : 'Blank leaves it in the year\'s surplus',
                  values: [if (!outflow) null, ...household.accounts],
                  value: household.accounts
                      .where((a) => a.id == accountId)
                      .firstOrNull,
                  describe: (a) => a?.label ?? 'Surplus',
                  onChanged: (a) => accountId = a?.id,
                ),
            ]),
            if (!outflow)
              EnumField<EventTaxTreatment>(
                label: 'Taxed as',
                values: EventTaxTreatment.values,
                value: treatment,
                onChanged: (v) => treatment = v,
              ),
            const SizedBox(height: 12),
            LabelledTextField(
              label: 'Name it (optional)',
              initial: label,
              onChanged: (v) => label = v,
            ),
            const SizedBox(height: 4),
            Note('Left blank, this will be called "${defaultEventLabel(household, kind: kind, year: year, excluding: existing?.id)}".'),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () {
                  notifier.saveOneTimeEvent(OneTimeEvent(
                    id: existing?.id ?? newId('ev'),
                    householdId: household.id,
                    personId: existing?.personId ??
                        (household.taxUnits.length > 1
                            ? household.people.firstOrNull?.id
                            : null),
                    label: label.trim().isEmpty
                        ? defaultEventLabel(household,
                            kind: kind, year: year, excluding: existing?.id)
                        : label.trim(),
                    year: year,
                    amount: outflow ? -amount : amount,
                    kind: kind,
                    accountId: accountId,
                    taxTreatment:
                        outflow ? EventTaxTreatment.nonTaxable : treatment,
                  ));
                  Navigator.of(context).pop();
                },
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _describe(ExpenseItem i, ExpenseCategory? c) {
    final phase = switch (i.phase) {
      ExpensePhase.preRetirementOnly => 'until retirement',
      ExpensePhase.postRetirementOnly => 'from retirement',
      ExpensePhase.both => i.postRetirementAmount == null
          ? 'throughout'
          : 'changes at retirement',
    };
    final inflation = i.relativeInflationRate ?? c?.defaultRelativeInflation ?? 0;
    final drift = inflation == 0
        ? 'flat in real terms'
        : '${formatPercent(inflation)} real';
    return '${c == null ? 'Uncategorised' : metaCategoryName(c.metaCategory)} · '
        '$phase · $drift';
  }

  Future<void> editExpense(
      BuildContext context, WidgetRef ref, ExpenseItem? existing,
      {MetaCategory? startingAt}) async {
    final household = ref.read(householdProvider);
    final notifier = ref.read(householdProvider.notifier);

    var label = existing?.label ?? '';
    var meta = existing == null
        ? startingAt ?? MetaCategory.misc
        : household.expenseCategories
                .where((c) => c.id == existing.categoryId)
                .firstOrNull
                ?.metaCategory ??
            MetaCategory.misc;
    var amount = existing?.amount ?? Money.zero;
    var frequency = existing?.frequency ?? ExpenseFrequency.monthly;
    var phase = existing?.phase ?? ExpensePhase.both;
    var afterRetirement = existing?.postRetirementAmount;
    var inflation = existing?.relativeInflationRate;
    var startYear = existing?.startYear;
    var endYear = existing?.endYear;
    var housingId = existing?.housingId;
    final thisYear = DateTime.now().year;

    await showEditor<void>(
      context,
      title: existing == null ? 'Add spending' : existing.label,
      build: (context) => StatefulBuilder(
        builder: (context, setState) {
          final homes = homesIn(household);
          final tiedHome =
              homes.where((h) => h.id == housingId).firstOrNull;
          return Column(
          children: [
            FieldRow([
              EnumField<MetaCategory>(
                label: 'What kind of cost',
                helper: metaCategoryBlurb(meta),
                values: MetaCategory.values,
                value: meta,
                describe: metaCategoryName,
                onChanged: (v) => setState(() => meta = v),
              ),
              EnumField<ExpenseFrequency>(
                label: 'How often',
                values: ExpenseFrequency.values,
                value: frequency,
                onChanged: (v) => setState(() => frequency = v),
              ),
            ]),
            FieldRow([
              MoneyField(
                label: 'Amount',
                initial: amount,
                onChanged: (v) => amount = v,
              ),
              PercentField(
                label: 'Rises faster than inflation by',
                helper: 'Blank means it keeps pace with inflation, which is '
                    'true of most things. Healthcare runs about 2.5% above.',
                initial: inflation,
                onChanged: (v) => inflation = v == 0 ? null : v,
              ),
            ]),
            if (meta == MetaCategory.housingSupport && homes.isNotEmpty) ...[
              const SizedBox(height: 12),
              SearchableField<HousingHome>(
                label: 'For which home',
                helper: 'Tax, dues and insurance belong to a particular roof '
                    'and run for exactly as long as it does. Left unattached '
                    'this keeps dates of its own.',
                values: homes,
                value: tiedHome,
                noneLabel: 'Not tied to one',
                describe: (h) => h.label,
                onChanged: (h) => setState(() {
                  housingId = h?.id;
                  if (h != null) {
                    startYear = h.fromYear;
                    endYear = h.toYear;
                  }
                }),
              ),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('When you pay it',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            const SizedBox(height: 8),
            ChoiceField<ExpensePhase>(
              label: 'Retirement',
              values: ExpensePhase.values,
              value: phase,
              describe: (p) => switch (p) {
                ExpensePhase.preRetirementOnly => 'Stops when I retire',
                ExpensePhase.postRetirementOnly => 'Only once I retire',
                ExpensePhase.both => 'Before and after I retire',
              },
              onChanged: (v) => setState(() => phase = v),
            ),
            if (phase == ExpensePhase.both) ...[
              const SizedBox(height: 12),
              MoneyField(
                label: 'And once retired, a year',
                helper: 'Only if the amount changes. Commuting falls away, '
                    'travel often goes up. Leave it blank to keep paying the '
                    'same.',
                initial: afterRetirement,
                onChanged: (v) => afterRetirement = v.isZero ? null : v,
              ),
            ],
            const SizedBox(height: 12),
            // A cost that follows a home has no dates of its own to show. Two
            // dropdowns that are really derived read as editable and go stale
            // the moment the home moves.
            if (tiedHome != null)
              Row(
                children: [
                  Expanded(
                    child: Note('Runs with ${tiedHome.name}'
                        '${tiedHome.spanPhrase}.'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => housingId = null),
                    child: const Text('Give it its own dates'),
                  ),
                ],
              )
            else
              FieldRow([
                NumberChoiceField(
                  label: 'Starts',
                  helper: 'Leave this alone for something you already pay.',
                  first: thisYear,
                  last: thisYear + 60,
                  value: startYear,
                  noneLabel: 'I already pay this',
                  onChanged: (v) => setState(() => startYear = v),
                ),
                NumberChoiceField(
                  label: 'Ends',
                  helper: 'Leave this alone for something with no end in '
                      'sight. Daycare runs six years, college four.',
                  first: thisYear,
                  last: thisYear + 60,
                  value: endYear,
                  noneLabel: 'It carries on',
                  onChanged: (v) => setState(() => endYear = v),
                ),
              ]),
            const SizedBox(height: 12),
            LabelledTextField(
              label: 'Name it (optional)',
              initial: label,
              onChanged: (v) => label = v,
            ),
            const SizedBox(height: 4),
            Note('Left blank, this will be called "${defaultExpenseLabel(household, meta: meta, excluding: existing?.id)}".'),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () {
                  // A category per meta-category, created on demand. Two levels
                  // is the domain's shape; asking a user to build the upper one
                  // before entering a grocery bill is not.
                  final category = household.expenseCategories
                          .where((c) => c.metaCategory == meta)
                          .firstOrNull ??
                      ExpenseCategory(
                        id: newId('cat'),
                        householdId: household.id,
                        label: metaCategoryName(meta),
                        metaCategory: meta,
                      );
                  notifier.saveCategory(category);
                  notifier.saveExpenseItem(ExpenseItem(
                    id: existing?.id ?? newId('exp'),
                    categoryId: category.id,
                    label: label.trim().isEmpty
                        ? defaultExpenseLabel(household,
                            meta: meta, excluding: existing?.id)
                        : label.trim(),
                    amount: amount * frequency.perYear,
                    frequency: ExpenseFrequency.annual,
                    startYear: startYear,
                    endYear: endYear,
                    relativeInflationRate: inflation,
                    phase: phase,
                    postRetirementAmount:
                        phase == ExpensePhase.both ? afterRetirement : null,
                    housingId: meta == MetaCategory.housingSupport
                        ? housingId
                        : null,
                  ));
                  Navigator.of(context).pop();
                },
                child: const Text('Save'),
              ),
            ),
          ],
        );
        },
      ),
    );
  }
}

/// "New roof, 2031". A one-off is remembered by when it happens as much as by
/// what it is.
String defaultEventLabel(
  Household household, {
  required OneTimeEventKind kind,
  required int year,
  Id? excluding,
}) {
  final what = switch (kind) {
    OneTimeEventKind.inheritance => 'Inheritance',
    OneTimeEventKind.tuition => 'Tuition',
    OneTimeEventKind.majorRepair => 'Major repair',
    OneTimeEventKind.vehiclePurchase => 'New car',
    OneTimeEventKind.windfall => 'Windfall',
    OneTimeEventKind.other => 'One-off',
  };
  return uniqueLabel(
      '$what, $year',
      household.oneTimeEvents
          .where((e) => e.id != excluding)
          .map((e) => e.label));
}

/// The category it belongs to, which is what most lines would be called anyway.
String defaultExpenseLabel(
  Household household, {
  required MetaCategory meta,
  Id? excluding,
}) =>
    uniqueLabel(
        metaCategoryName(meta),
        household.expenseItems
            .where((i) => i.id != excluding)
            .map((i) => i.label));

/// A home a housing cost can be attached to: somewhere owned, or the rent
/// being paid for somewhere that is not.
class HousingHome {
  final Id id;
  final String name;
  final int? fromYear;
  final int? toYear;

  const HousingHome({
    required this.id,
    required this.name,
    this.fromYear,
    this.toYear,
  });

  /// The years alone, for use after a name that has already been said.
  String get spanPhrase {
    if (fromYear == null && toYear == null) return ', for as long as you have it';
    if (toYear == null) return ', from $fromYear on';
    if (fromYear == null) return ', until $toYear';
    return ', $fromYear to $toYear';
  }

  /// Named with its years, since two homes in one plan are told apart by when
  /// rather than by what they are called.
  String get label {
    if (fromYear == null && toYear == null) return name;
    if (toYear == null) return '$name, from $fromYear';
    if (fromYear == null) return '$name, until $toYear';
    return '$name, $fromYear to $toYear';
  }
}

/// Everywhere this household lives, or will.
///
/// An owned home runs from the year it is acquired to the year before it is
/// sold; rent runs on its own dates.
List<HousingHome> homesIn(Household household) {
  final housing = household.expenseCategories
      .where((c) => c.metaCategory == MetaCategory.housing)
      .map((c) => c.id)
      .toSet();
  return [
    for (final a in household.assets)
      if (a.category == AssetCategory.primaryResidence)
        HousingHome(
          id: a.id,
          name: a.label,
          fromYear: a.acquisitionYear,
          toYear: a.plannedSaleYear == null ? null : a.plannedSaleYear! - 1,
        ),
    for (final i in household.expenseItems)
      if (housing.contains(i.categoryId))
        HousingHome(
          id: i.id,
          name: i.label,
          fromYear: i.startYear,
          toYear: i.endYear,
        ),
  ];
}

/// One home's running costs, under its name.
class _HomeGroup extends StatelessWidget {
  final String title;
  final List<ExpenseItem> items;
  final String Function(ExpenseItem) describe;
  final void Function(ExpenseItem) onTap;
  final void Function(ExpenseItem) onDelete;

  const _HomeGroup({
    required this.title,
    required this.items,
    required this.describe,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = sumMoney(items.map((i) => i.amount));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Row(
            children: [
              Icon(Icons.home_outlined,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
              Text('${formatMoney(total)} a year',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        for (final item in items)
          EntityTile(
            icon: Icons.receipt_long_outlined,
            title: item.label,
            subtitle: describe(item),
            trailing: formatMoneyCompact(item.amount),
            onTap: () => onTap(item),
            onDelete: () => onDelete(item),
          ),
      ],
    );
  }
}
