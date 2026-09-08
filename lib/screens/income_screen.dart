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
      blurb: 'What the household earns, what it pays for out of payroll, and '
          'who it works for.',
      addLabel: '',
      emptyMessage: '',
      banner: const FlagBanner(home: FlagHome.income),
      children: [
        EntitySection(
          title: 'Employers',
          blurb: 'Naming an employer lets us tie a job to the retirement plan '
              'it sponsors, which is how an employer match is worked out.',
          addLabel: 'Add an employer',
          onAdd: canAdd ? () => editEmployer(context, ref, null) : null,
          emptyMessage: canAdd
              ? 'Optional. Add one if your job comes with a 401(k) match.'
              : null,
          children: [
            for (final employer in household.employers)
              EntityTile(
                icon: Icons.business_outlined,
                title: employer.label,
                subtitle: _employerSummary(employer, household),
                onTap: () => editEmployer(context, ref, employer),
                onDelete: () => notifier.removeEmployer(employer.id),
              ),
          ],
        ),
        EntitySection(
          title: 'Income',
          addLabel: 'Add income',
          onAdd: canAdd ? () => editIncome(context, ref, null) : null,
          emptyMessage: canAdd
              ? 'Nothing yet. Earned income stops at retirement; a pension or '
                  'a rental does not.'
              : 'Add a person on the Household screen first. Income belongs to '
                  'someone, since the Social Security wage base and every '
                  'contribution limit are worked out per person.',
          children: [
            for (final stream in household.incomeStreams)
              EntityTile(
                icon: stream.kind.isEarned
                    ? Icons.work_outline
                    : Icons.account_balance_outlined,
                title: stream.label,
                subtitle: _describe(stream, household),
                trailing: formatMoneyCompact(stream.grossAnnualAmount),
                onTap: () => editIncome(context, ref, stream),
                onDelete: () => notifier.removeIncomeStream(stream.id),
              ),
          ],
        ),
        EntitySection(
          title: 'Taken from your pay',
          blurb: 'Money that never reaches your bank account: health premiums, '
              'an FSA, a commuter benefit.',
          addLabel: 'Add a payroll deduction',
          onAdd: canAdd ? () => editDeduction(context, ref, null) : null,
          emptyMessage: canAdd ? 'Nothing yet.' : null,
          children: [
            for (final deduction in household.payrollDeductions)
              EntityTile(
                icon: Icons.medical_services_outlined,
                title: deduction.label,
                subtitle: _describeDeduction(deduction, household),
                trailing: formatMoneyCompact(deduction.annualAmount),
                onTap: () => editDeduction(context, ref, deduction),
                onDelete: () => notifier.removePayrollDeduction(deduction.id),
              ),
          ],
        ),
      ],
    );
  }

  /// A deduction reads differently for each person who has one, so two FSAs in
  /// a household of two are told apart at a glance.
  static String _describeDeduction(PayrollDeduction d, Household h) {
    final owner = h.personById(d.personId)?.displayName;
    final parts = <String>[
      if (owner != null && h.people.length > 1) owner,
      humanise(d.kind.name),
      if (d.reducesFicaWages) 'before tax and Social Security' else 'before tax',
    ];
    return parts.join(' · ');
  }

  /// An `Employer` holds no figures of its own. It exists so a stream and an
  /// account can point at the same one, which is what lets §415(c) and the
  /// match see the pay behind a plan.
  static String _employerSummary(Employer e, Household h) {
    final streams = h.incomeStreams.where((s) => s.employerId == e.id).length;
    final accounts = h.accounts.where((a) => a.employerId == e.id).length;
    if (streams == 0 && accounts == 0) {
      return 'Not linked to anything yet. Pick it on a job above, and on the '
          'plan it sponsors under Accounts.';
    }
    final parts = <String>[
      if (streams > 0) '$streams job${streams == 1 ? '' : 's'}',
      if (accounts > 0) '$accounts account${accounts == 1 ? '' : 's'}',
    ];
    return 'Linked to ${parts.join(' and ')}';
  }

  Future<void> editEmployer(
      BuildContext context, WidgetRef ref, Employer? existing) async {
    final household = ref.read(householdProvider);
    final notifier = ref.read(householdProvider.notifier);
    var label = existing?.label ?? '';

    await showEditor<void>(
      context,
      title: existing == null ? 'Add an employer' : existing.label,
      build: (context) => Column(
        children: [
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
  Future<void> editDeduction(
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
            Note(
              'This is for money that is spent, not saved: a health premium, '
              'an FSA, a transit pass. It comes out before tax, and whatever '
              'is left at the end of the year is gone.\n\n'
              'A 401(k) or HSA contribution also comes out of your pay, but it '
              'is still your money and it grows. Add those under Accounts so '
              'they count toward what you are worth.',
            ),
            const SizedBox(height: 16),
            FieldRow([
              EnumField<PayrollDeductionKind>(
                label: 'Kind',
                values: PayrollDeductionKind.values,
                value: kind,
                onChanged: (v) => setState(() => kind = v),
              ),
              MoneyField(
                label: 'Cost per year',
                helper: 'What comes out of your pay over a full year, in '
                    "today's dollars.",
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
                onChanged: (p) => setState(() => personId = p.id),
              ),
            const SizedBox(height: 12),
            FieldRow([
              YearField(
                label: 'Start year',
                helper: 'Leave blank if it is already coming out of your pay.',
                initial: startYear,
                onChanged: (v) => startYear = v,
              ),
              YearField(
                label: 'End year',
                helper: kind.isCoverageRelated
                    ? 'Leave blank to end it when your health coverage through '
                        'work does.'
                    : 'Leave blank to end it when you retire.',
                initial: endYear,
                onChanged: (v) => endYear = v,
              ),
            ]),
            const SizedBox(height: 12),
            LabelledTextField(
              label: 'Name it (optional)',
              initial: label,
              onChanged: (v) => label = v,
            ),
            const SizedBox(height: 4),
            Note('Left blank, this will be called '
                '"${_defaultDeductionLabel(household, personId, kind)}".'),
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
                    label: label.trim().isEmpty
                        ? _defaultDeductionLabel(household, personId, kind)
                        : label.trim(),
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

  Future<void> editIncome(
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
    var employerId = existing?.employerId;
    final thisYear = DateTime.now().year;

    await showEditor<void>(
      context,
      title: existing == null ? 'Add income' : existing.label,
      build: (context) => StatefulBuilder(
        builder: (context, setState) => Column(
          children: [
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
                  onChanged: (p) => setState(() => personId = p.id),
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
              NumberChoiceField(
                label: 'Starts',
                helper: 'Leave blank if you are already being paid this.',
                first: thisYear,
                last: thisYear + 60,
                value: startYear,
                noneLabel: 'Already running',
                onChanged: (v) => setState(() {
                  startYear = v;
                  if (v == null) startMonth = null;
                }),
              ),
              if (startYear != null)
                NumberChoiceField(
                  label: 'From which month',
                  first: 1,
                  last: 12,
                  value: startMonth ?? 1,
                  describe: (m) => monthNames[m - 1],
                  onChanged: (v) => startMonth = v,
                ),
            ]),
            FieldRow([
              NumberChoiceField(
                label: 'Ends',
                helper: 'Leave blank to stop it when you retire.',
                first: thisYear,
                last: thisYear + 60,
                value: endYear,
                noneLabel: 'When I retire',
                onChanged: (v) => setState(() {
                  endYear = v;
                  if (v == null) endMonth = null;
                }),
              ),
              if (endYear != null)
                NumberChoiceField(
                  label: 'Through which month',
                  helper: 'Set this and the next job\'s start month so a '
                      'year with two jobs is not counted twice.',
                  first: 1,
                  last: 12,
                  value: endMonth ?? 12,
                  describe: (m) => monthNames[m - 1],
                  onChanged: (v) => endMonth = v,
                ),
            ]),
            if (household.employers.isNotEmpty)
              SearchableField<Employer>(
                label: 'Employer',
                helper: 'Who pays it. This is how a 401(k) and its match find '
                    'the pay they come out of.',
                values: household.employers,
                value: household.employers
                    .where((e) => e.id == employerId)
                    .firstOrNull,
                noneLabel: 'Nobody, I work for myself',
                describe: (e) => e.label,
                onChanged: (e) => setState(() => employerId = e?.id),
              ),
            const SizedBox(height: 12),
            LabelledTextField(
              label: 'Name it (optional)',
              initial: label,
              onChanged: (v) => label = v,
            ),
            const SizedBox(height: 4),
            Note('Left blank, this will be called '
                '"${_defaultIncomeLabel(household, personId, employerId, kind)}".'),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () {
                  notifier.saveIncomeStream(IncomeStream(
                    id: existing?.id ?? newId('inc'),
                    personId: personId,
                    employerId: employerId,
                    label: label.trim().isEmpty
                        ? _defaultIncomeLabel(
                            household, personId, employerId, kind)
                        : label.trim(),
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
                    // Bonuses and RSUs are not money you can count on, and the
                    // kind already says which is which, so it is derived
                    // rather than asked a second time.
                    variability: existing?.variability ??
                        (kind == IncomeKind.bonus ||
                                kind == IncomeKind.rsuVesting
                            ? IncomeVariability.variable
                            : IncomeVariability.guaranteed),
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

/// "Masha's health FSA", so two FSAs in one household are told apart without
/// anyone having to name them.
String _defaultDeductionLabel(
    Household h, Id personId, PayrollDeductionKind kind) {
  final name = h.personById(personId)?.displayName;
  final what = switch (kind) {
    PayrollDeductionKind.healthPremium => 'health premium',
    PayrollDeductionKind.dentalVisionPremium => 'dental and vision',
    PayrollDeductionKind.healthFsa => 'health FSA',
    PayrollDeductionKind.dependentCareFsa => 'dependent care FSA',
    PayrollDeductionKind.commuterBenefit => 'commuter benefit',
    PayrollDeductionKind.other => 'payroll deduction',
  };
  return name == null ? humanise(what) : "$name's $what";
}

/// "Alex at Acme", or "Alex's salary" where no employer is named. A label
/// nobody has to think of is one fewer thing between a user and their number.
String _defaultIncomeLabel(
    Household h, Id personId, Id? employerId, IncomeKind kind) {
  final name = h.personById(personId)?.displayName;
  final employer =
      h.employers.where((e) => e.id == employerId).firstOrNull?.label;
  final what = switch (kind) {
    IncomeKind.w2Wages => 'salary',
    IncomeKind.selfEmployment => 'self-employment',
    IncomeKind.bonus => 'bonus',
    IncomeKind.rsuVesting => 'shares',
    IncomeKind.rentalNet => 'rental income',
    IncomeKind.pension => 'pension',
    IncomeKind.other => 'income',
  };
  if (employer != null) return '${name ?? 'Income'} at $employer';
  return name == null ? humanise(what) : "$name's $what";
}
