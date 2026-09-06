import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

final taxYear =
    parseTaxYear(File('../../assets/tax_years/2026.json').readAsStringSync());
final asOf = DateTime(2026, 1, 1);

ExpenseCategory living() => const ExpenseCategory(
      id: 'cat',
      householdId: 'h1',
      label: 'Living',
      metaCategory: MetaCategory.misc,
    );

ExpenseItem spend(num annual) => ExpenseItem(
      id: 'e1',
      categoryId: 'cat',
      label: 'Living',
      amount: Money.dollars(annual),
    );

/// A household with a lot saved and a modest cost of living, so a solve
/// terminates quickly.
Household wealthy({
  int birthYear = 1975,
  num pay = 200000,
  num spending = 60000,
  num taxable = 1500000,
  num deferred = 800000,
  num rothBasis = 250000,
  int? plannedRetirementAge,
}) =>
    Household(
      id: 'h1',
      taxUnits: [taxUnit()],
      people: [
        person(birthYear: birthYear, plannedRetirementAge: plannedRetirementAge)
      ],
      incomeStreams: [salary(pay: pay)],
      accounts: [
        brokerageIn(balance: taxable, basis: taxable * 0.7),
        traditional401k(balance: deferred),
        Account(
          id: 'roth',
          personId: 'p1',
          label: 'Roth IRA',
          kind: AccountKind.rothIra,
          taxTreatment: TaxTreatment.roth,
          limitFamily: LimitFamily.ira,
          balance: Money.dollars(rothBasis * 1.5),
          rothContributionBasis: Money.dollars(rothBasis),
          isRestrictedPurpose: false,
          assetAllocationId: 'stocks',
          contribution:
              const Contribution(mode: ContributionMode.fixedAmount, value: 0),
        ),
      ],
      expenseCategories: [living()],
      expenseItems: [spend(spending)],
    );

BandResult solve(Household h, {BandName band = BandName.expected}) =>
    solveRetirement(
      h,
      assumptions: const Assumptions(taxYearId: 'us-2026'),
      taxYear: taxYear,
      assetClasses: assetClasses(),
      asOfDate: asOf,
      band: band,
    );

void main() {
  group('§8.2 the retirement test', () {
    test('a well-funded household reaches a year', () {
      final r = solve(wealthy());
      expect(r.retirementYear, isNotNull);
      expect(r.fireNumber, isNotNull);
      expect(r.retirementYear! >= 2026, isTrue);
    });

    test('a household that never gets there is notReachable, not blank', () {
      // High spending against almost nothing saved.
      final r = solve(wealthy(
        pay: 45000,
        spending: 44000,
        taxable: 1000,
        deferred: 0,
        rothBasis: 0,
      ));
      expect(r.retirementYear, isNull);
      expect(r.fireNumber, isNull,
          reason: 'a FIRE number has no duration to be sized over');
      expect(r.shortfall, isNotNull,
          reason: 'never a blank, and never an arbitrarily distant year');
    });

    test('all three legs are recorded for every candidate', () {
      final r = solve(wealthy(taxable: 200000, deferred: 100000));
      expect(r.candidates, isNotEmpty);
      final first = r.candidates.first;
      expect(first.fire.fireNumber.isPositive, isTrue);
      expect(first.bridge.years > 0, isTrue,
          reason: 'a 1975 birth year retiring now has a bridge to cross');
    });

    test('leg 3 runs only where legs 1 and 2 already pass', () {
      final r = solve(wealthy(taxable: 50000, deferred: 20000, rothBasis: 0));
      final failing =
          r.candidates.where((c) => !c.clearsFireNumber).toList();
      expect(failing, isNotEmpty);
      expect(failing.every((c) => !c.survivesHorizon), isTrue,
          reason: 'the expensive leg is never reached');
    });
  });

  group('§8.2 a fixed retirement age', () {
    test('takes the person out of the search entirely', () {
      final r = solve(wealthy(plannedRetirementAge: 60));
      expect(r.retirementYear, 1975 + 60);
      expect(r.candidates, isEmpty,
          reason: 'no circularity to solve, so no candidates evaluated');
    });

    test('§9.4 reports what the plan will support, and the headroom', () {
      final r = solve(wealthy(plannedRetirementAge: 60));
      expect(r.sustainableLevelSpending, isNotNull);
      expect(r.spendingHeadroom, isNotNull);
      expect(
        r.spendingHeadroom,
        r.sustainableLevelSpending! -
            _levelEquivalent(r),
      );
    });
  });

  group('§8.3 the bridge', () {
    test('tax-deferred money does not count toward it', () {
      // Deliberately conservative: conversion ladders, 72(t) and the Rule of 55
      // are all real routes the engine does not model (§13.3).
      final household = wealthy(taxable: 10000, deferred: 3000000, rothBasis: 0);
      final accounts = {
        for (final a in household.accounts) a.id: AccountState(a),
      };
      final bridge = checkBridge(
        household: household,
        accounts: accounts,
        retirementYear: 2026,
        annualSpending: Money.dollars(60000),
        annualQualifiedMedical: Money.zero,
      );
      expect(bridge.bridgeGapDetected, isTrue);
      expect(bridge.eligibleAssets < Money.dollars(3000000), isTrue);
    });

    test('Roth basis counts and Roth growth does not', () {
      final household = wealthy(taxable: 0, deferred: 0, rothBasis: 400000);
      final accounts = {
        for (final a in household.accounts) a.id: AccountState(a),
      };
      final bridge = checkBridge(
        household: household,
        accounts: accounts,
        retirementYear: 2026,
        annualSpending: Money.dollars(20000),
        annualQualifiedMedical: Money.zero,
      );
      // The account holds 600,000 with 400,000 of basis.
      expect(bridge.eligibleAssets, Money.dollars(400000));
    });

    test('a household already past 59½ has no bridge to cross', () {
      final household = wealthy(birthYear: 1955);
      final accounts = {
        for (final a in household.accounts) a.id: AccountState(a),
      };
      final bridge = checkBridge(
        household: household,
        accounts: accounts,
        retirementYear: 2026,
        annualSpending: Money.dollars(60000),
        annualQualifiedMedical: Money.zero,
      );
      expect(bridge.years, 0);
      expect(bridge.bridgeGapDetected, isFalse);
    });
  });

  group('§8.2 across the bands', () {
    test('a worse market pushes the date out, or off the end', () {
      final h = wealthy(taxable: 400000, deferred: 300000, rothBasis: 100000);
      final low = solve(h, band: BandName.pessimistic);
      final high = solve(h, band: BandName.optimistic);

      if (low.retirementYear != null && high.retirementYear != null) {
        expect(high.retirementYear! <= low.retirementYear!, isTrue);
      } else {
        expect(high.retirementYear, isNotNull,
            reason: 'the optimistic band should not be the one that fails');
      }
    });

    test('all three bands are solved together', () {
      final bands = solveAllBands(
        wealthy(),
        assumptions: const Assumptions(taxYearId: 'us-2026'),
        taxYear: taxYear,
        assetClasses: assetClasses(),
        asOfDate: asOf,
      );
      expect(bands.values.length, 3);
      expect(bands.expected.band, BandName.expected);
    });
  });
}

Money _levelEquivalent(BandResult r) {
  final atRetirement = r.finalPass.yearOf(r.retirementYear!)!;
  final stream = r.finalPass.years
      .where((y) => y.year >= r.retirementYear!)
      .map((y) => y.solved.cashFlow.annualExpenses)
      .toList();
  expect(atRetirement.year, r.retirementYear);
  return computeFireNumber(stream: stream, safeWithdrawalRate: 0.04)
      .levelEquivalentRetirementExpenses;
}
