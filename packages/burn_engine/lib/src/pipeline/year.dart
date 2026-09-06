/// The §4.3 ⇄ §4.4 fixed point: one whole year, solved.
///
/// Tax depends on contributions and contributions depend on what is left after
/// tax, so the two are solved together. It is bounded rather than iterated to
/// convergence: each pass's correction is roughly the marginal rate times the
/// previous delta, so it settles in two passes and three is a generous ceiling
/// (§4.4.3).
library;

import '../entities/assumptions.dart';
import '../entities/household.dart';
import '../taxyear/tax_year.dart';
import '../types.dart';
import 'federal_tax.dart';
import 'income_tax.dart';
import 'limits.dart';
import 'surplus.dart';
import 'wages.dart';

/// Everything one projected year produced.
class YearResult {
  final int year;
  final List<PersonWages> wages;
  final List<TaxableIncome> incomes;
  final List<TaxOwed> owed;
  final List<ResolvedContribution> contributions;
  final CashFlow cashFlow;

  /// How many passes the fixed point took.
  final int passes;

  /// Raised where the allocation was still moving when the ceiling was reached
  /// (§4.4.3).
  final bool waterfallNotConverged;

  const YearResult({
    required this.year,
    required this.wages,
    required this.incomes,
    required this.owed,
    required this.contributions,
    required this.cashFlow,
    required this.passes,
    required this.waterfallNotConverged,
  });

  Money get totalTaxOwed => cashFlow.totalTaxOwed;
  Money get netSurplus => cashFlow.netSurplus;
}

/// §4.1 through §4.5 for one year, with the retirement year handed in.
///
/// [proposedContributions] is how the waterfall asks "what if this much more
/// went in": the solve re-prices tax with those included, which is exactly the
/// residue §4.4.3 describes.
YearResult solveYear(
  Household household, {
  required Assumptions assumptions,
  required TaxYear taxYear,
  required Map<Id, AssetClass> assetClasses,
  required int year,
  required int currentYear,
  required int? retirementYear,
  YearInputs inputs = const YearInputs(),
  Map<Id, WithdrawalPenalties> penalties = const {},
  Map<Id, Money> proposedContributions = const {},
  int maxPasses = 3,
}) {
  var requested = Map<Id, Money>.from(proposedContributions);
  List<ResolvedContribution>? contributions;
  var passes = 0;
  var converged = false;

  late List<PersonWages> wages;
  late List<TaxableIncome> incomes;
  late List<TaxOwed> owed;
  late CashFlow cashFlow;

  while (passes < maxPasses) {
    passes++;

    // Contribution limits first: what the household is allowed to put in does
    // not depend on tax, only on pay and age.
    contributions = [
      for (final person in household.people)
        ...resolveContributions(
          person,
          household: household,
          taxYear: taxYear,
          year: year,
          currentYear: currentYear,
          requested: requested,
        ),
    ];
    final resolved = {
      for (final c in contributions) c.accountId: c.employee,
    };

    wages = [
      for (final person in household.people)
        computeWages(
          person,
          household: household,
          taxYear: taxYear,
          year: year,
          currentYear: currentYear,
          resolvedContributions: resolved,
        ),
    ];

    final withInputs = YearInputs(
      rmdIncome: inputs.rmdIncome,
      realizedGainsOnDraws: inputs.realizedGainsOnDraws,
      assetSaleTaxableGain: inputs.assetSaleTaxableGain,
      assetSaleRecapture: inputs.assetSaleRecapture,
      annualDepreciation: inputs.annualDepreciation,
      studentLoanInterestPaid: inputs.studentLoanInterestPaid,
      resolvedContributions: resolved,
    );

    incomes = [
      for (final unit in household.taxUnits)
        computeTaxableIncome(
          unit,
          household: household,
          assumptions: assumptions,
          taxYear: taxYear,
          assetClasses: assetClasses,
          wages: wages,
          year: year,
          currentYear: currentYear,
          inputs: withInputs,
        ),
    ];

    owed = [
      for (var i = 0; i < household.taxUnits.length; i++)
        computeTaxOwed(
          household.taxUnits[i],
          household: household,
          income: incomes[i],
          wages: wages,
          assumptions: assumptions,
          taxYear: taxYear,
          year: year,
          currentYear: currentYear,
          inputs: withInputs,
          penalties: penalties[household.taxUnits[i].id] ??
              const WithdrawalPenalties(),
        ),
    ];

    cashFlow = computeCashFlow(
      household,
      assumptions: assumptions,
      wages: wages,
      incomes: incomes,
      owed: owed,
      contributions: contributions,
      year: year,
      currentYear: currentYear,
      retirementYear: retirementYear,
      inputs: withInputs,
    );

    // Nothing was proposed, so there is no residue to settle.
    if (requested.isEmpty) {
      converged = true;
      break;
    }

    // The allocation stops moving when what the limits allowed equals what was
    // asked for; a further pass would re-price the same figures.
    final moved = contributions.any((c) =>
        requested.containsKey(c.accountId) &&
        requested[c.accountId] != c.employee);
    if (!moved) {
      converged = true;
      break;
    }
    requested = {
      for (final c in contributions)
        if (requested.containsKey(c.accountId)) c.accountId: c.employee,
    };
  }

  return YearResult(
    year: year,
    wages: wages,
    incomes: incomes,
    owed: owed,
    contributions: contributions!,
    cashFlow: cashFlow,
    passes: passes,
    waterfallNotConverged: !converged,
  );
}
