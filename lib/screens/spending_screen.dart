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

    return EntityList(
      title: 'Spending',
      blurb: 'What the household spends now, and what changes at retirement.',
      addLabel: 'Add spending',
      emptyMessage:
          'Add what the household spends.\nLeave out mortgage payments, '
          'payroll deductions and health premiums: each reaches the plan '
          'through its own term already.',
      banner: const FlagBanner(home: FlagHome.spending),
      onAdd: () => _edit(context, ref, null),
      children: [
        for (final item in household.expenseItems)
          EntityTile(
            icon: Icons.receipt_long_outlined,
            title: item.label,
            subtitle: _describe(item, categories[item.categoryId]),
            trailing: formatMoneyCompact(item.amount),
            onTap: () => _edit(context, ref, item),
            onDelete: () => notifier.removeExpenseItem(item.id),
          ),
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
            onTap: () => _editEvent(context, ref, event),
            onDelete: () => notifier.removeOneTimeEvent(event.id),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton.icon(
            onPressed: () => _editEvent(context, ref, null),
            icon: const Icon(Icons.event_outlined),
            label: const Text('Add a one-off'),
          ),
        ),
      ],
    );
  }

  /// §3.8. A single dated inflow or outflow: an inheritance, a roof, a truck.
  ///
  /// An outflow must say where the money comes from, since where the $40,000
  /// for a truck comes from changes the projection materially and only the
  /// user knows.
  Future<void> _editEvent(
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
    // An outflow must name its source (invariant 17), so it starts on one
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
            LabelledTextField(
              label: 'Label',
              initial: label,
              onChanged: (v) => label = v,
            ),
            const SizedBox(height: 12),
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
                    label: label.isEmpty ? humanise(kind.name) : label,
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
    return '${c == null ? 'Uncategorised' : humanise(c.metaCategory.name)} · '
        '$phase · $drift';
  }

  Future<void> _edit(
      BuildContext context, WidgetRef ref, ExpenseItem? existing) async {
    final household = ref.read(householdProvider);
    final notifier = ref.read(householdProvider.notifier);

    var label = existing?.label ?? '';
    var meta = existing == null
        ? MetaCategory.misc
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

    await showEditor<void>(
      context,
      title: existing == null ? 'Add spending' : existing.label,
      build: (context) => StatefulBuilder(
        builder: (context, setState) => Column(
          children: [
            LabelledTextField(
              label: 'Label',
              initial: label,
              onChanged: (v) => label = v,
            ),
            const SizedBox(height: 12),
            FieldRow([
              EnumField<MetaCategory>(
                label: 'Category',
                helper: meta == MetaCategory.health
                    ? 'Health spending caps HSA withdrawals'
                    : meta == MetaCategory.education
                        ? 'Education spending draws a 529 down'
                        : null,
                values: MetaCategory.values,
                value: meta,
                onChanged: (v) => setState(() => meta = v),
              ),
              EnumField<ExpenseFrequency>(
                label: 'How often',
                helper: 'Normalised to a year on save',
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
                label: 'Real inflation',
                helper: 'Healthcare ≈ +2.5%, groceries ≈ 0%',
                initial: inflation,
                onChanged: (v) => inflation = v,
              ),
            ]),
            FieldRow([
              EnumField<ExpensePhase>(
                label: 'When',
                values: ExpensePhase.values,
                value: phase,
                describe: (p) => switch (p) {
                  ExpensePhase.preRetirementOnly => 'Until retirement',
                  ExpensePhase.postRetirementOnly => 'From retirement',
                  ExpensePhase.both => 'Throughout',
                },
                onChanged: (v) => setState(() => phase = v),
              ),
              if (phase == ExpensePhase.both)
                MoneyField(
                  label: 'After retirement',
                  helper: 'Leave blank if it does not change',
                  initial: afterRetirement,
                  onChanged: (v) =>
                      afterRetirement = v.isZero ? null : v,
                ),
            ]),
            FieldRow([
              YearField(
                label: 'Start year',
                initial: startYear,
                onChanged: (v) => startYear = v,
              ),
              YearField(
                label: 'End year',
                helper: 'Daycare for six years, college for four',
                initial: endYear,
                onChanged: (v) => endYear = v,
              ),
            ]),
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
                        label: humanise(meta.name),
                        metaCategory: meta,
                      );
                  notifier.saveCategory(category);
                  notifier.saveExpenseItem(ExpenseItem(
                    id: existing?.id ?? newId('exp'),
                    categoryId: category.id,
                    label: label.isEmpty ? humanise(meta.name) : label,
                    amount: amount * frequency.perYear,
                    frequency: ExpenseFrequency.annual,
                    startYear: startYear,
                    endYear: endYear,
                    relativeInflationRate: inflation,
                    phase: phase,
                    postRetirementAmount:
                        phase == ExpensePhase.both ? afterRetirement : null,
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
}
