import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../services/flag_placement.dart';
import '../widgets/entity_list.dart';
import '../widgets/flag_banner.dart';
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
      banner: const FlagBanner(home: FlagHome.income),
      onAdd: canAdd ? () => _edit(context, ref, null) : null,
      children: [
        for (final employer in household.employers)
          EntityTile(
            icon: Icons.business_outlined,
            title: employer.label,
            subtitle: _employerSummary(employer, household),
            onTap: () => _editEmployer(context, ref, employer),
            onDelete: () => notifier.removeEmployer(employer.id),
          ),
        if (household.employers.isNotEmpty) const SizedBox(height: 4),
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
        for (final deduction in household.payrollDeductions)
          EntityTile(
            icon: Icons.medical_services_outlined,
            title: deduction.label,
            subtitle: '${humanise(deduction.kind.name)} · '
                '${deduction.reducesFicaWages ? 'reduces FICA wages' : 'income tax only'}',
            trailing: formatMoneyCompact(deduction.annualAmount),
            onTap: () => _editDeduction(context, ref, deduction),
            onDelete: () => notifier.removePayrollDeduction(deduction.id),
          ),
        if (canAdd)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _editEmployer(context, ref, null),
                  icon: const Icon(Icons.business_outlined),
                  label: const Text('Add an employer'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _editDeduction(context, ref, null),
                  icon: const Icon(Icons.medical_services_outlined),
                  label: const Text('Add a payroll deduction'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// An `Employer` holds no figures of its own. It exists so a stream and an
  /// account can point at the same one, which is what lets §415(c) and the
  /// match see the pay behind a plan.
  static String _employerSummary(Employer e, Household h) {
    final streams = h.incomeStreams.where((s) => s.employerId == e.id).length;
    final accounts = h.accounts.where((a) => a.employerId == e.id).length;
    return '$streams income · $accounts account${accounts == 1 ? '' : 's'}';
  }

  Future<void> _editEmployer(
      BuildContext context, WidgetRef ref, Employer? existing) async {
    final household = ref.read(householdProvider);
    final notifier = ref.read(householdProvider.notifier);
    var label = existing?.label ?? '';

    await showEditor<void>(
      context,
      title: existing == null ? 'Add an employer' : existing.label,
      build: (context) => Column(
        children: [
          Text(
            'An employer is just a name two things can point at. Linking a '
            'job and the plan it sponsors is what lets the engine see the pay '
            'behind an employer match and the §415(c) ceiling.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          LabelledTextField(
            label: 'Name',
            initial: label,
            onChanged: (v) => label = v,
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: () {
                notifier.saveEmployer(Employer(
                  id: existing?.id ?? newId('emp'),
                  householdId: household.id,
                  label: label.isEmpty ? 'Employer' : label,
                ));
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }

  /// §3.4.5. Pre-tax money that is spent rather than saved.
  Future<void> _editDeduction(
      BuildContext context, WidgetRef ref, PayrollDeduction? existing) async {
    final household = ref.read(householdProvider);
    final notifier = ref.read(householdProvider.notifier);

    var label = existing?.label ?? '';
    var personId = existing?.personId ?? household.people.first.id;
    var kind = existing?.kind ?? PayrollDeductionKind.healthPremium;
    var amount = existing?.annualAmount ?? Money.zero;
    var startYear = existing?.startYear;
    var endYear = existing?.endYear;

    await showEditor<void>(
      context,
      title: existing == null ? 'Add a payroll deduction' : existing.label,
      build: (context) => StatefulBuilder(
        builder: (context, setState) => Column(
          children: [
            Text(
              'Money that never reaches the paycheck: a health premium, an '
              'FSA election, a commuter benefit. Cafeteria-plan items under '
              '§125 also reduce FICA wages, which a 401(k) deferral does not.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            LabelledTextField(
              label: 'Label',
              initial: label,
              onChanged: (v) => label = v,
            ),
            const SizedBox(height: 12),
            FieldRow([
              EnumField<PayrollDeductionKind>(
                label: 'Kind',
                values: PayrollDeductionKind.values,
                value: kind,
                onChanged: (v) => setState(() => kind = v),
              ),
              MoneyField(
                label: 'A year',
                initial: amount,
                onChanged: (v) => amount = v,
              ),
            ]),
            if (household.people.length > 1)
              ChoiceField<Person>(
                label: 'Whose',
                values: household.people,
                value: household.personById(personId),
                describe: (p) => p.displayName,
                onChanged: (p) => personId = p.id,
              ),
            const SizedBox(height: 12),
            FieldRow([
              YearField(
                label: 'Start year',
                initial: startYear,
                onChanged: (v) => startYear = v,
              ),
              YearField(
                label: 'End year',
                helper: kind.isCoverageRelated
                    ? 'Blank ends it with employer coverage'
                    : 'Blank ends it at retirement',
                initial: endYear,
                onChanged: (v) => endYear = v,
              ),
            ]),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () {
                  // §125 and §132(f) items reach FICA wages; nothing else does.
                  final cafeteria = kind != PayrollDeductionKind.other;
                  notifier.savePayrollDeduction(PayrollDeduction(
                    id: existing?.id ?? newId('pd'),
                    personId: personId,
                    label: label.isEmpty ? humanise(kind.name) : label,
                    kind: kind,
                    annualAmount: amount,
                    reducesFederalTaxableIncome: true,
                    reducesStateTaxableIncome: true,
                    reducesFicaWages: cafeteria,
                    startYear: startYear,
                    endYear: endYear,
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
    var employerId = existing?.employerId;

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
            if (household.employers.isNotEmpty)
              ChoiceField<Employer?>(
                label: 'Employer',
                helper: 'Links this pay to the plan it sponsors',
                values: [null, ...household.employers],
                value: household.employers
                    .where((e) => e.id == employerId)
                    .firstOrNull,
                describe: (e) => e?.label ?? 'None',
                onChanged: (e) => employerId = e?.id,
              ),
            if (household.employers.isNotEmpty) const SizedBox(height: 12),
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
                    employerId: employerId,
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
