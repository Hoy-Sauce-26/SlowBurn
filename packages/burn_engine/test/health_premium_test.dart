import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

final taxYear =
    parseTaxYear(File('../../assets/tax_years/2026.json').readAsStringSync());
const year = 2040;

Household family({
  int children = 0,
  int? coverageEnds,
  int adults = 1,
}) =>
    Household(
      id: 'h1',
      taxUnits: [
        TaxUnit(
          id: 'tu1',
          householdId: 'h1',
          filingStatus: FilingStatus.single,
          stateCode: 'CO',
          dependents: [
            for (var i = 0; i < children; i++)
              Dependent(id: 'd$i', birthDate: DateTime(2028 + i, 6, 15)),
          ],
        ),
      ],
      people: [
        for (var i = 0; i < adults; i++)
          Person(
            id: 'p$i',
            displayName: 'Adult $i',
            birthDate: DateTime(1985, 6, 15),
            taxUnitId: 'tu1',
            employerHealthCoverageEndYear: coverageEnds ?? 2030,
          ),
      ],
      incomeStreams: [salary(pay: 60000)],
    );

HealthCredit healthFor(Household h) {
  final wages = h.people
      .map((p) => computeWages(p,
          household: h, taxYear: taxYear, year: year, currentYear: 2026))
      .toList();
  final income = computeTaxableIncome(h.taxUnits.first,
      household: h,
      assumptions: const Assumptions(taxYearId: 'us-2026'),
      taxYear: taxYear,
      assetClasses: assetClasses(),
      wages: wages,
      year: year,
      currentYear: 2026);
  return computeTaxOwed(h.taxUnits.first,
          household: h,
          income: income,
          wages: wages,
          assumptions: const Assumptions(taxYearId: 'us-2026'),
          taxYear: taxYear,
          year: year,
          currentYear: 2026)
      .health;
}

void main() {
  group('§4.3.5 the premium is per head', () {
    test('each adult buying their own cover is priced', () {
      final one = healthFor(family());
      final two = healthFor(family(adults: 2));
      expect(two.benchmarkPremium.cents, greaterThan(one.benchmarkPremium.cents));
    });

    test('children are priced too, having raised the subsidy already', () {
      // The gap: a dependent raised taxUnitSize, and so the poverty line the
      // subsidy is measured against, while adding nothing to the premium. A
      // family retiring with two children looked cheaper than a couple.
      final childless = healthFor(family());
      final withKids = healthFor(family(children: 2));

      expect(withKids.taxUnitSize, childless.taxUnitSize + 2);
      expect(withKids.benchmarkPremium.cents,
          greaterThan(childless.benchmarkPremium.cents));
    });

    test('nobody is priced while a job still covers the household', () {
      final working = healthFor(family(children: 2, coverageEnds: 2050));
      expect(working.benchmarkPremium, Money.zero,
          reason: 'one policy, and somebody else is paying for it');
    });

    test('an entered override replaces the whole sum', () {
      final h = family(children: 2);
      final overridden = Household(
        id: h.id,
        taxUnits: [
          TaxUnit(
            id: 'tu1',
            householdId: 'h1',
            filingStatus: FilingStatus.single,
            stateCode: 'CO',
            dependents: h.taxUnits.first.dependents,
            benchmarkPremiumOverride: Money.dollars(21000),
          ),
        ],
        people: h.people,
        incomeStreams: h.incomeStreams,
      );
      expect(healthFor(overridden).benchmarkPremium, Money.dollars(21000),
          reason: 'a real quote beats a national average every time');
    });
  });

  group('§3.2 a dependent planned for a later year', () {
    Household expecting(int born) => Household(
          id: 'h1',
          taxUnits: [
            TaxUnit(
              id: 'tu1',
              householdId: 'h1',
              filingStatus: FilingStatus.single,
              stateCode: 'CO',
              dependents: [Dependent(id: 'd1', birthDate: DateTime(born, 6, 15))],
            ),
          ],
          people: [
            Person(
              id: 'p0',
              displayName: 'Alex',
              birthDate: DateTime(1985, 6, 15),
              taxUnitId: 'tu1',
              employerHealthCoverageEndYear: 2030,
            ),
          ],
          incomeStreams: [salary(pay: 60000)],
        );

    test('costs nothing and counts for nothing before they arrive', () {
      final h = expecting(2045);
      expect(h.taxUnits.first.activeDependents(2040), isEmpty,
          reason: 'typing a plan is not the same as having a child');
      expect(h.taxUnits.first.qualifyingChildren(2040, 17), 0);
    });

    test('and everything from the year they do', () {
      final h = expecting(2045);
      expect(h.taxUnits.first.activeDependents(2045), hasLength(1));
      expect(h.taxUnits.first.qualifyingChildren(2045, 17), 1);
    });

    test('raises the premium only once they are here', () {
      final before = healthFor(expecting(2045));
      final after = healthFor(expecting(2035));
      expect(after.benchmarkPremium.cents,
          greaterThan(before.benchmarkPremium.cents),
          reason: 'the 2040 projection houses one of them and not the other');
      expect(after.taxUnitSize, before.taxUnitSize + 1);
    });

    test('and stops counting once support ends', () {
      final h = expecting(2030);
      expect(h.taxUnits.first.activeDependents(2049), hasLength(1));
      expect(h.taxUnits.first.activeDependents(2050), isEmpty,
          reason: 'nineteen years after 2030');
    });
  });
}
