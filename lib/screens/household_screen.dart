import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/flag_placement.dart';
import '../services/providers.dart';
import '../widgets/entity_list.dart';
import '../widgets/fields.dart';
import '../widgets/flag_banner.dart';

/// §3.1 and §3.2. Who is in the plan, and how they file.
///
/// People come first and the tax return sits under them. The people are what
/// the user came to enter; the filing details are a consequence.
class HouseholdScreen extends ConsumerWidget {
  const HouseholdScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final household = ref.watch(householdProvider);
    final notifier = ref.read(householdProvider.notifier);

    return EntityList(
      title: 'Household',
      blurb: 'Who is in the plan, and how they file.',
      addLabel: 'Add a person',
      emptyMessage: 'Start with yourself.',
      banner: const FlagBanner(home: FlagHome.household),
      onAdd: () => editPerson(context, ref, null),
      children: [
        for (final person in household.people)
          EntityTile(
            icon: Icons.person_outline,
            title: person.displayName,
            subtitle: _describe(person),
            onTap: () => editPerson(context, ref, person),
            onDelete: () => notifier.removePerson(person.id),
          ),
        for (final unit in household.taxUnits) TaxUnitCard(unit: unit),
      ],
    );
  }

  static String _describe(Person p) {
    final parts = <String>[
      'Born ${monthNames[p.birthDate.month - 1]} ${p.birthDate.year}',
      if (p.plannedRetirementAge != null)
        'retiring at ${p.plannedRetirementAge}'
      else
        'we will work out when they can retire',
      if (p.socialSecurity != null)
        'Social Security from ${p.socialSecurity!.claimingAge}',
    ];
    return parts.join(' · ');
  }

  Future<void> editPerson(
    BuildContext context,
    WidgetRef ref,
    Person? existing,
  ) async {
    final household = ref.read(householdProvider);
    final notifier = ref.read(householdProvider.notifier);
    final thisYear = DateTime.now().year;

    // The first person brings a tax return with them, since someone with no
    // return is not a state anyone means to be in. It is created on save
    // rather than on opening the form, so cancelling leaves nothing behind.
    final unitId =
        existing?.taxUnitId ??
        (household.taxUnits.isEmpty
            ? newId('tu')
            : household.taxUnits.first.id);
    void ensureTaxUnit() {
      if (ref.read(householdProvider).taxUnits.isEmpty) {
        notifier.saveTaxUnit(
          TaxUnit(
            id: unitId,
            householdId: household.id,
            filingStatus: FilingStatus.single,
            stateCode: 'CO',
          ),
        );
      }
    }

    var name = existing?.displayName ?? '';
    var birthYear = existing?.birthDate.year ?? thisYear - 40;
    var birthMonth = existing?.birthDate.month ?? 6;
    var plannedAge = existing?.plannedRetirementAge;
    var coverageEnd = existing?.employerHealthCoverageEndYear;
    var hsaTier = existing?.hsaCoverage.lastOrNull?.tier ?? HsaTier.none;
    var benefit = existing?.socialSecurity;
    var hasBenefit = benefit != null;
    var benefitAmount = benefit?.estimatedMonthlyBenefitAtFra ?? Money.zero;
    var claimingAge = benefit?.claimingAge ?? 67;
    var countOnIt = benefit?.includeInProjection ?? true;

    await showEditor<void>(
      context,
      title: existing == null ? 'Add a person' : existing.displayName,
      build: (context) => StatefulBuilder(
        builder: (context, setState) {
          // Coverage almost always ends when the job does, so the year is
          // worked out rather than asked for. It only becomes a question once
          // a retirement age is known to extrapolate from.
          final defaultCoverageEnd = plannedAge == null
              ? null
              : birthYear + plannedAge! - 1;

          return Column(
            children: [
              LabelledTextField(
                label: 'Name',
                initial: name,
                onChanged: (v) => name = v,
              ),
              const SizedBox(height: 12),
              FieldRow([
                NumberChoiceField(
                  label: 'Birth year',
                  first: thisYear - 90,
                  last: thisYear,
                  value: birthYear,
                  descending: true,
                  onChanged: (v) => setState(() => birthYear = v ?? birthYear),
                ),
                NumberChoiceField(
                  label: 'Birth month',
                  first: 1,
                  last: 12,
                  value: birthMonth,
                  describe: (m) => monthNames[m - 1],
                  onChanged: (v) =>
                      setState(() => birthMonth = v ?? birthMonth),
                ),
              ]),
              FieldRow([
                NumberChoiceField(
                  label: 'Plan to retire at',
                  helper:
                      'Pick an age to test, or let us work out the '
                      'earliest year you could.',
                  first: 40,
                  last: 75,
                  value: plannedAge,
                  noneLabel: 'Work it out for me',
                  onChanged: (v) => setState(() {
                    plannedAge = v;
                    if (v == null) coverageEnd = null;
                  }),
                ),
                if (plannedAge != null)
                  NumberChoiceField(
                    label: 'Health coverage through work ends',
                    helper:
                        'We assume it ends with the job. Change it if a '
                        'retiree plan carries on.',
                    first: thisYear,
                    last: birthYear + 90,
                    value: coverageEnd ?? defaultCoverageEnd,
                    onChanged: (v) => coverageEnd = v ?? defaultCoverageEnd,
                  ),
              ]),
              if (plannedAge == null)
                Note(
                  'Once you set a retirement age we will also ask when your '
                  'health coverage through work ends, since buying your own is '
                  'usually the largest cost of retiring early.',
                ),
              const SizedBox(height: 4),
              EnumField<HsaTier>(
                label: 'Do you pay into an HSA through your health plan?',
                values: HsaTier.values,
                value: hsaTier,
                describe: (t) => switch (t) {
                  HsaTier.none => 'No',
                  HsaTier.self => 'Yes, just me',
                  HsaTier.family => 'Yes, my family is covered too',
                },
                onChanged: (v) => setState(() => hsaTier = v),
              ),
              const SizedBox(height: 20),
              _Section('Social Security'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Include Social Security benefits in this plan',
                ),
                subtitle: const Text(
                  'Turn this off to see how the plan looks without it',
                ),
                value: hasBenefit,
                onChanged: (v) => setState(() => hasBenefit = v),
              ),
              if (hasBenefit) ...[
                Note(
                  'Your Social Security statement at ssa.gov shows a monthly '
                  'benefit at your full retirement age. Enter that figure, '
                  'and we will adjust it for the age you actually claim.',
                ),
                const SizedBox(height: 12),
                FieldRow([
                  MoneyField(
                    label: 'Monthly benefit',
                    helper: 'The figure at your full retirement age',
                    initial: benefitAmount,
                    onChanged: (v) => benefitAmount = v,
                  ),
                  NumberChoiceField(
                    label: 'Claim at age',
                    helper: 'Claiming later means a larger cheque for life.',
                    first: 62,
                    last: 70,
                    value: claimingAge,
                    onChanged: (v) =>
                        setState(() => claimingAge = v ?? claimingAge),
                  ),
                ]),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('I am counting on this benefit'),
                  subtitle: const Text(
                    'Turn it off to leave this person\'s benefit out while '
                    'keeping someone else\'s in',
                  ),
                  value: countOnIt,
                  onChanged: (v) => setState(() => countOnIt = v),
                ),
              ],
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () {
                    ensureTaxUnit();
                    final id = existing?.id ?? newId('p');
                    notifier.savePerson(
                      Person(
                        id: id,
                        displayName: name.trim().isEmpty
                            ? 'Unnamed'
                            : name.trim(),
                        birthDate: DateTime(birthYear, birthMonth, 15),
                        taxUnitId: unitId,
                        plannedRetirementAge: plannedAge,
                        hsaCoverage: hsaTier == HsaTier.none
                            ? const []
                            : [
                                HsaCoverageEntry(
                                  fromYear: thisYear,
                                  tier: hsaTier,
                                ),
                              ],
                        employerHealthCoverageEndYear: plannedAge == null
                            ? null
                            : coverageEnd ?? defaultCoverageEnd,
                        socialSecurity: hasBenefit
                            ? SocialSecurityBenefit(
                                personId: id,
                                estimatedMonthlyBenefitAtFra: benefitAmount,
                                claimingAge: claimingAge,
                                includeInProjection: countOnIt,
                              )
                            : null,
                      ),
                    );
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

class _Section extends StatelessWidget {
  final String title;

  const _Section(this.title);

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    ),
  );
}

/// The return itself, under the people who file it.
class TaxUnitCard extends ConsumerWidget {
  final TaxUnit unit;

  const TaxUnitCard({super.key, required this.unit});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(householdProvider.notifier);
    // Silence is the enemy: a state with no bundled rules charges nothing, and
    // a zero that means "we do not know" must not look like a zero that means
    // "no tax here" (§7.6).
    final covered = ref
        .watch(taxYearProvider)
        .maybeWhen(
          data: (y) => y.stateRules.containsKey(unit.stateCode),
          orElse: () => true,
        );
    TaxUnit edited({
      FilingStatus? status,
      String? state,
      List<Dependent>? dependents,
    }) => TaxUnit(
      id: unit.id,
      householdId: unit.householdId,
      filingStatus: status ?? unit.filingStatus,
      stateCode: state ?? unit.stateCode,
      localityCode: unit.localityCode,
      dependents: dependents ?? unit.dependents,
      benchmarkPremiumOverride: unit.benchmarkPremiumOverride,
      itemizedDeductionTotal: unit.itemizedDeductionTotal,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How you file', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            FieldRow([
              EnumField<FilingStatus>(
                label: 'Filing status',
                values: FilingStatus.values,
                value: unit.filingStatus,
                onChanged: (v) => notifier.saveTaxUnit(edited(status: v)),
              ),
              SearchableField<String>(
                label: 'State',
                helper: covered
                    ? null
                    : 'We do not have ${usStateCodes[unit.stateCode]}\'s rules '
                          'in this tax year yet, so state tax is showing as zero.',
                values: usStateCodes.keys.toList(),
                value: unit.stateCode,
                describe: (code) => usStateCodes[code]!,
                onChanged: (code) => notifier.saveTaxUnit(edited(state: code)),
              ),
            ]),
            // Children are not people in the plan: they earn nothing and hold
            // nothing. What they do is bring a credit and count toward the
            // household size every subsidy is measured against (§3.2).
            EntitySection(
              title: 'Children and dependants',
              blurb: 'Each one brings a tax credit while they qualify, and '
                  'counts toward the household size behind any health '
                  'subsidy.',
              addLabel: 'Add a dependant',
              emptyMessage: 'Nobody depending on this return.',
              onAdd: () => _editDependent(context, ref, null),
              children: [
                for (final (index, dependent) in unit.dependents.indexed)
                  EntityTile(
                    icon: Icons.child_care_outlined,
                    title: 'Born ${dependent.birthDate.year}',
                    subtitle: 'supported through '
                        '${dependent.resolvedSupportEndYear}'
                        '${dependent.isStudent ? ' · student' : ''}',
                    onTap: () => _editDependent(context, ref, index),
                    onDelete: () => notifier.saveTaxUnit(edited(
                        dependents: [...unit.dependents]..removeAt(index))),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Dependants are a list on the return rather than entities of their own, so
  /// they are edited by position.
  Future<void> _editDependent(
      BuildContext context, WidgetRef ref, int? index) async {
    final notifier = ref.read(householdProvider.notifier);
    final existing = index == null ? null : unit.dependents[index];
    final thisYear = DateTime.now().year;

    var birthYear = existing?.birthDate.year ?? thisYear;
    var isStudent = existing?.isStudent ?? false;
    var supportEnd = existing?.supportEndYear;

    await showEditor<void>(
      context,
      title: index == null ? 'Add a dependant' : 'Born $birthYear',
      build: (context) => StatefulBuilder(
        builder: (context, setState) => Column(
          children: [
            NumberChoiceField(
              label: 'Born',
              helper: 'The credit follows their age, and stops the year they '
                  'turn 17.',
              first: thisYear - 30,
              last: thisYear,
              descending: true,
              value: birthYear,
              onChanged: (v) => setState(() => birthYear = v ?? thisYear),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Still in full-time education'),
              subtitle: const Text(
                  'Support is assumed to run to 24 rather than 19.'),
              value: isStudent,
              onChanged: (v) => setState(() => isStudent = v),
            ),
            const SizedBox(height: 12),
            NumberChoiceField(
              label: 'You support them until',
              helper: 'Left alone, this is the year they turn '
                  '${isStudent ? 24 : 19}.',
              first: thisYear,
              last: thisYear + 40,
              value: supportEnd,
              noneLabel: 'Work it out for me',
              onChanged: (v) => setState(() => supportEnd = v),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () {
                  final dependent = Dependent(
                    birthDate: DateTime(birthYear, 6, 15),
                    isStudent: isStudent,
                    supportEndYear: supportEnd,
                  );
                  final all = [...unit.dependents];
                  if (index == null) {
                    all.add(dependent);
                  } else {
                    all[index] = dependent;
                  }
                  notifier.saveTaxUnit(TaxUnit(
                    id: unit.id,
                    householdId: unit.householdId,
                    filingStatus: unit.filingStatus,
                    stateCode: unit.stateCode,
                    localityCode: unit.localityCode,
                    dependents: all,
                    benchmarkPremiumOverride: unit.benchmarkPremiumOverride,
                    itemizedDeductionTotal: unit.itemizedDeductionTotal,
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
