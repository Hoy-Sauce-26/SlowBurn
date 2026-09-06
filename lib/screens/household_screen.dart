import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../widgets/entity_list.dart';
import '../widgets/fields.dart';

/// §3.1 and §3.2. Who is in the plan, and how they file.
///
/// A `TaxUnit` is created alongside the first person rather than asked for
/// separately: a household with a person and no return is not a state anyone
/// means to be in, and invariant 3 would flag it immediately.
class HouseholdScreen extends ConsumerWidget {
  const HouseholdScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final household = ref.watch(householdProvider);
    final notifier = ref.read(householdProvider.notifier);

    return EntityList(
      title: 'Household',
      blurb: 'Who is in the plan, when they were born, and how they file.',
      addLabel: 'Add a person',
      emptyMessage:
          'Start with yourself.\nBirth date drives 59½ access, catch-up '
          'eligibility, Medicare at 65 and Social Security.',
      onAdd: () => _editPerson(context, ref, null),
      children: [
        for (final unit in household.taxUnits)
          _TaxUnitCard(unit: unit, household: household),
        for (final person in household.people)
          EntityTile(
            icon: Icons.person_outline,
            title: person.displayName,
            subtitle: _describe(person, household),
            onTap: () => _editPerson(context, ref, person),
            onDelete: () => notifier.removePerson(person.id),
          ),
      ],
    );
  }

  static String _describe(Person p, Household h) {
    final unit = h.taxUnitById(p.taxUnitId);
    final parts = <String>[
      'Born ${p.birthDate.year}',
      if (unit != null) humanise(unit.filingStatus.name),
      if (p.plannedRetirementAge != null)
        'Retiring at ${p.plannedRetirementAge}'
      else
        'Retirement year solved for',
    ];
    return parts.join(' · ');
  }

  Future<void> _editPerson(
      BuildContext context, WidgetRef ref, Person? existing) async {
    final household = ref.read(householdProvider);
    final notifier = ref.read(householdProvider.notifier);

    // The first person brings a tax unit with them.
    var unitId = existing?.taxUnitId ??
        (household.taxUnits.isEmpty ? newId('tu') : household.taxUnits.first.id);
    if (household.taxUnits.isEmpty) {
      notifier.saveTaxUnit(TaxUnit(
        id: unitId,
        householdId: household.id,
        filingStatus: FilingStatus.single,
        stateCode: 'CO',
      ));
    }

    var name = existing?.displayName ?? '';
    var birthYear = existing?.birthDate.year ?? 1985;
    var birthMonth = existing?.birthDate.month ?? 6;
    var plannedAge = existing?.plannedRetirementAge;
    var coverageEnd = existing?.employerHealthCoverageEndYear;

    await showEditor<void>(
      context,
      title: existing == null ? 'Add a person' : existing.displayName,
      build: (context) => StatefulBuilder(
        builder: (context, setState) => Column(
          children: [
            LabelledTextField(
              label: 'Name',
              initial: name,
              onChanged: (v) => name = v,
            ),
            const SizedBox(height: 12),
            FieldRow([
              YearField(
                label: 'Birth year',
                initial: birthYear,
                onChanged: (v) => birthYear = v ?? birthYear,
              ),
              YearField(
                label: 'Birth month',
                helper: '59½ is computed from the date',
                initial: birthMonth,
                onChanged: (v) => birthMonth = (v ?? birthMonth).clamp(1, 12),
              ),
            ]),
            FieldRow([
              YearField(
                label: 'Planned retirement age',
                helper: 'Leave blank to solve for it',
                initial: plannedAge,
                onChanged: (v) => plannedAge = v,
              ),
              YearField(
                label: 'Employer coverage ends',
                helper: 'Last year on an employer health plan',
                initial: coverageEnd,
                onChanged: (v) => coverageEnd = v,
              ),
            ]),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () {
                  notifier.savePerson(Person(
                    id: existing?.id ?? newId('p'),
                    displayName: name.isEmpty ? 'Unnamed' : name,
                    birthDate: DateTime(birthYear, birthMonth, 15),
                    taxUnitId: unitId,
                    plannedRetirementAge: plannedAge,
                    hsaCoverage: existing?.hsaCoverage ?? const [],
                    employerHealthCoverageEndYear: coverageEnd,
                    socialSecurity: existing?.socialSecurity,
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

class _TaxUnitCard extends ConsumerWidget {
  final TaxUnit unit;
  final Household household;

  const _TaxUnitCard({required this.unit, required this.household});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(householdProvider.notifier);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tax return',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            FieldRow([
              EnumField<FilingStatus>(
                label: 'Filing status',
                values: FilingStatus.values,
                value: unit.filingStatus,
                onChanged: (v) => notifier.saveTaxUnit(TaxUnit(
                  id: unit.id,
                  householdId: unit.householdId,
                  filingStatus: v,
                  stateCode: unit.stateCode,
                  localityCode: unit.localityCode,
                  dependents: unit.dependents,
                  benchmarkPremiumOverride: unit.benchmarkPremiumOverride,
                  itemizedDeductionTotal: unit.itemizedDeductionTotal,
                )),
              ),
              LabelledTextField(
                label: 'State',
                initial: unit.stateCode,
                onChanged: (v) => notifier.saveTaxUnit(TaxUnit(
                  id: unit.id,
                  householdId: unit.householdId,
                  filingStatus: unit.filingStatus,
                  stateCode: v.toUpperCase(),
                  localityCode: unit.localityCode,
                  dependents: unit.dependents,
                  benchmarkPremiumOverride: unit.benchmarkPremiumOverride,
                  itemizedDeductionTotal: unit.itemizedDeductionTotal,
                )),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
