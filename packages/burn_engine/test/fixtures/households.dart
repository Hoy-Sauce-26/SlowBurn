/// Households the tests build on. Deliberately small: each one exists to make
/// exactly one rule visible.
library;

import 'package:burn_engine/burn_engine.dart';

Account brokerage({
  String id = 'acct-taxable',
  String personId = 'p1',
  num balance = 100000,
  num basis = 60000,
}) =>
    Account(
      id: id,
      personId: personId,
      label: 'Brokerage',
      kind: AccountKind.taxableBrokerage,
      taxTreatment: TaxTreatment.taxable,
      limitFamily: LimitFamily.none,
      balance: Money.dollars(balance),
      costBasis: Money.dollars(basis),
      isRestrictedPurpose: false,
      contribution: const Contribution(
        mode: ContributionMode.fixedAmount,
        value: 0,
      ),
    );

Account traditional401k({
  String id = 'acct-401k',
  String personId = 'p1',
  num balance = 250000,
  Contribution? contribution,
  String? employerId,
}) =>
    Account(
      id: id,
      personId: personId,
      label: '401(k)',
      kind: AccountKind.traditional401k,
      taxTreatment: TaxTreatment.taxDeferred,
      limitFamily: LimitFamily.electiveDeferral,
      balance: Money.dollars(balance),
      employerId: employerId,
      isRestrictedPurpose: false,
      contribution: contribution ??
          const Contribution(
            mode: ContributionMode.fixedAmount,
            value: 0,
            reducesFederalTaxableIncome: true,
            reducesStateTaxableIncome: true,
          ),
    );

Person person({
  String id = 'p1',
  String name = 'Alex',
  int birthYear = 1985,
  String taxUnitId = 'tu1',
  int? plannedRetirementAge,
  SocialSecurityBenefit? socialSecurity,
}) =>
    Person(
      id: id,
      displayName: name,
      birthDate: DateTime(birthYear, 6, 15),
      taxUnitId: taxUnitId,
      plannedRetirementAge: plannedRetirementAge,
      socialSecurity: socialSecurity,
    );

TaxUnit taxUnit({
  String id = 'tu1',
  FilingStatus filingStatus = FilingStatus.single,
  String state = 'CO',
  List<Dependent> dependents = const [],
}) =>
    TaxUnit(
      id: id,
      householdId: 'h1',
      filingStatus: filingStatus,
      stateCode: state,
      dependents: dependents,
    );

IncomeStream salary({
  String id = 'inc-1',
  String personId = 'p1',
  num pay = 150000,
  String? employerId,
  int? startYear,
  int? endYear,
  int? startMonth,
  int? endMonth,
}) =>
    IncomeStream(
      id: id,
      personId: personId,
      employerId: employerId,
      label: 'Salary',
      kind: IncomeKind.w2Wages,
      grossAnnualAmount: Money.dollars(pay),
      startYear: startYear,
      endYear: endYear,
      startMonth: startMonth,
      endMonth: endMonth,
      isFicaSubject: true,
      isQualifiedBusinessIncome: false,
    );

/// One person, one job, one 401(k), one brokerage account. Valid.
Household simpleHousehold() => Household(
      id: 'h1',
      taxUnits: [taxUnit()],
      people: [person()],
      incomeStreams: [salary()],
      accounts: [traditional401k(), brokerage()],
    );
