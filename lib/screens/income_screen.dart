import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../widgets/entity_list.dart';
import '../widgets/fields.dart';

/// §3.3. What the household earns, and for how long.
///
/// The months are the interesting field here: without them a job change makes
/// both salaries fully active in the transition year, which overstates it by
/// close to a whole salary.
class IncomeScreen extends ConsumerWidget {
  const IncomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final household = ref.watch(householdProvider);
    final notifier = ref.read(householdProvider.notifier);
    final canAdd = household.people.isNotEmpty;

    return EntityList(
      title: 'Income',
      blurb: 'Salary, self-employment, rentals and pensions.',
      addLabel: 'Add income',
      emptyMessage: canAdd
          ? 'Add what the household earns.\nEarned income stops at retirement; '
              'a pension or rental does not.'
          : 'Add a person first: income belongs to someone, since the wage base '
              'and every contribution limit are per individual.',
      onAdd: canAdd ? () => _edit(context, ref, null) : null,
      children: [
        for (final stream in household.incomeStreams)
          EntityTile(
            icon: stream.kind.isEarned
                ? Icons.work_outline
                : Icons.account_balance_outlined,
            title: stream.label,
            subtitle: _describe(stream, household),
            trailing: formatMoneyCompact(stream.grossAnnualAmount),
            onTap: () => _edit(context, ref, stream),
            onDelete: () => notifier.removeIncomeStream(stream.id),
          ),
      ],
    );
  }

  static String _describe(IncomeStream s, Household h) {
    final owner = h.personById(s.personId)?.displayName ?? 'Unassigned';
    final span = switch ((s.startYear, s.endYear)) {
      (null, null) => 'ongoing',
      (null, final e?) => 'until $e',
      (final b?, null) => 'from $b',
      (final b?, final e?) => '$b to $e',
    };
    return '$owner · ${humanise(s.kind.name)} · $span';
  }

  Future<void> _edit(
      BuildContext context, WidgetRef ref, IncomeStream? existing) async {
    final household = ref.read(householdProvider);
    final notifier = ref.read(householdProvider.notifier);

    var label = existing?.label ?? '';
    var personId = existing?.personId ?? household.people.first.id;
    var kind = existing?.kind ?? IncomeKind.w2Wages;
    var amount = existing?.grossAnnualAmount ?? Money.zero;
    var growth = existing?.realGrowthRate ?? 0.0;
    var startYear = existing?.startYear;
    var endYear = existing?.endYear;
    var startMonth = existing?.startMonth;
    var endMonth = existing?.endMonth;
    var variability = existing?.variability ?? IncomeVariability.guaranteed;

    await showEditor<void>(
      context,
      title: existing == null ? 'Add income' : existing.label,
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
              EnumField<IncomeKind>(
                label: 'Kind',
                helper: 'Earned income stops at retirement',
                values: IncomeKind.values,
                value: kind,
                onChanged: (v) => setState(() => kind = v),
              ),
              if (household.people.length > 1)
                ChoiceField<Person>(
                  label: 'Whose',
                  values: household.people,
                  value: household.personById(personId),
                  describe: (p) => p.displayName,
                  onChanged: (p) => personId = p.id,
                ),
            ]),
            FieldRow([
              MoneyField(
                label: 'Annual amount',
                helper: 'The full-year rate, in today\'s dollars',
                initial: amount,
                onChanged: (v) => amount = v,
              ),
              PercentField(
                label: 'Real growth',
                helper: '0% keeps pace with inflation',
                initial: growth,
                onChanged: (v) => growth = v,
              ),
            ]),
            FieldRow([
              YearField(
                label: 'Start year',
                helper: 'Blank means already running',
                initial: startYear,
                onChanged: (v) => startYear = v,
              ),
              YearField(
                label: 'Start month',
                helper: '1–12, blank means January',
                initial: startMonth,
                onChanged: (v) => startMonth = v,
              ),
            ]),
            FieldRow([
              YearField(
                label: 'End year',
                helper: 'Blank ends it at retirement',
                initial: endYear,
                onChanged: (v) => endYear = v,
              ),
              YearField(
                label: 'End month',
                helper: 'Set both across a job change',
                initial: endMonth,
                onChanged: (v) => endMonth = v,
              ),
            ]),
            EnumField<IncomeVariability>(
              label: 'Dependability',
              helper: 'Display only: a plan resting on bonuses is worth seeing',
              values: IncomeVariability.values,
              value: variability,
              onChanged: (v) => variability = v,
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () {
                  notifier.saveIncomeStream(IncomeStream(
                    id: existing?.id ?? newId('inc'),
                    personId: personId,
                    employerId: existing?.employerId,
                    label: label.isEmpty ? humanise(kind.name) : label,
                    kind: kind,
                    grossAnnualAmount: amount,
                    realGrowthRate: growth,
                    startYear: startYear,
                    endYear: endYear,
                    startMonth: startMonth,
                    endMonth: endMonth,
                    isFicaSubject: existing?.isFicaSubject ??
                        defaultIsFicaSubject(kind),
                    isQualifiedBusinessIncome:
                        existing?.isQualifiedBusinessIncome ??
                            defaultIsQualifiedBusinessIncome(kind),
                    isSpecifiedServiceBusiness:
                        existing?.isSpecifiedServiceBusiness ?? false,
                    variability: variability,
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
