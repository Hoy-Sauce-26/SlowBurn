/// §4.4 and §4.5. What the household has left, and where it goes.
///
/// Per **Household**. Every sum here spans the whole household, unlike §4.3's,
/// which are per `TaxUnit`.
library;

import '../entities/assumptions.dart';
import '../entities/household.dart';
import '../loop/housing.dart';
import '../enums.dart';
import '../types.dart';
import 'federal_tax.dart';
import 'income_tax.dart';
import 'limits.dart';
import 'wages.dart';

/// One year's cash flow for the whole household (§4.4).
class CashFlow {
  final Money grossIncome;
  final Money oneTimeNet;
  final Money education529Draw;
  final Money payrollDeductions;
  final Money committedContribs;
  final Money totalTaxOwed;

  final Money expenseItemTotal;
  final Money debtService;
  final Money healthInsurance;

  const CashFlow({
    required this.grossIncome,
    required this.oneTimeNet,
    required this.education529Draw,
    required this.payrollDeductions,
    required this.committedContribs,
    required this.totalTaxOwed,
    required this.expenseItemTotal,
    required this.debtService,
    required this.healthInsurance,
  });

  /// The household's whole cost of living, and it has exactly one definition
  /// (§4.4): the cash-buffer target and the FIRE number are both built on it.
  Money get annualExpenses => expenseItemTotal + debtService + healthInsurance;

  /// What ordinary money has to pay for, the 529's share of tuition taken
  /// out. This is what retirement is sized on (§8.1): a 529 sits outside
  /// `liquidNetWorth`, so counting the tuition it pays in the target as well
  /// would charge for it twice.
  Money get expensesFromLiquid => annualExpenses - education529Draw;

  Money get netSurplus =>
      grossIncome +
      oneTimeNet +
      education529Draw -
      payrollDeductions -
      committedContribs -
      totalTaxOwed -
      annualExpenses;
}

/// §4.4 for one year, given the tax already computed for each unit.
CashFlow computeCashFlow(
  Household household, {
  required Assumptions assumptions,
  required List<PersonWages> wages,
  required List<TaxableIncome> incomes,
  required List<TaxOwed> owed,
  required List<ResolvedContribution> contributions,
  required int year,
  required int currentYear,
  required int? retirementYear,
  YearInputs inputs = const YearInputs(),
}) {
  // Wages, salaries and profits, plus everything received as cash. No
  // in-account investment income: it never leaves the account (§4.4).
  final grossIncome = sumMoney(wages.map((w) => w.wageIncome + w.seEarnings)) +
      sumMoney(incomes.map((i) =>
          i.rentalIncome + i.pensionIncome + i.otherStreamIncome)) +
      sumMoney(incomes.map((i) => i.ssBenefits)) +
      inputs.rmdIncome;

  final payrollDeductions = sumMoney(household.payrollDeductions
      .where((d) => d.activeIn(year))
      .map((d) => d.resolvedAmount(year)));

  // Covers every tax treatment, taxable included: a standing brokerage deposit
  // is committed money like a deferral is (§4.4).
  final committedContribs =
      sumMoney(contributions.map((c) => c.employee));

  final categories = {for (final c in household.expenseCategories) c.id: c};
  final expenseItemTotal = sumMoney(household.expenseItems.map((item) {
    // The tax and dues on a house stop when the house is sold. Left running,
    // a plan pays forty years of upkeep on somewhere it no longer owns (§3.7).
    if (!housingCostStandsIn(household, item, year,
        retirementYear: retirementYear)) {
      return Money.zero;
    }
    final category = categories[item.categoryId];
    return item.amountIn(
      year,
      currentYear: currentYear,
      retirementYear: retirementYear,
      categoryDefaultInflation: category?.defaultRelativeInflation ?? 0,
    );
  }));

  // Restricted education money is spent on what restricts it (§4.4): without
  // this the 529 would compound untouched while tuition came out of the
  // retirement accounts.
  final educationSpending = sumMoney(household.expenseItems
      .where((i) =>
          categories[i.categoryId]?.metaCategory == MetaCategory.education)
      .map((i) => i.amountIn(
            year,
            currentYear: currentYear,
            retirementYear: retirementYear,
            categoryDefaultInflation:
                categories[i.categoryId]?.defaultRelativeInflation ?? 0,
          )));
  final restrictedBalance = inputs.restrictedBalance ??
      sumMoney(household.accounts
          .where((a) => a.isRestrictedPurpose)
          .map((a) => a.balance));
  final education529Draw = minMoney(restrictedBalance, educationSpending);

  final debtService = sumMoney(household.liabilities
      .where((l) => l.currentBalance.isPositive)
      .map((l) => (l.monthlyPayment + l.extraPrincipalPayment) * 12));

  // An engine term the user never maintains, for the years the household buys
  // its own coverage (§4.4).
  final healthInsurance = sumMoney(owed.map((o) => o.health.netPremium));

  final oneTimeNet = sumMoney(household.oneTimeEvents
      .where((e) => e.year == year && e.accountId == null)
      .map((e) => e.amount));

  return CashFlow(
    grossIncome: grossIncome,
    oneTimeNet: oneTimeNet,
    education529Draw: education529Draw,
    payrollDeductions: payrollDeductions,
    committedContribs: committedContribs,
    totalTaxOwed: sumMoney(owed.map((o) => o.totalTaxOwed)),
    expenseItemTotal: expenseItemTotal,
    debtService: debtService,
    healthInsurance: healthInsurance,
  );
}

/// §4.5. The Money target a cash-buffer account is topped up to this year.
///
/// Months of `annualExpenses` rather than a fixed sum, since expenses change
/// year to year.
Money cashBufferTarget(double months, Money annualExpenses) =>
    annualExpenses * (months / 12);
