import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../widgets/entity_list.dart';
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
      ],
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
