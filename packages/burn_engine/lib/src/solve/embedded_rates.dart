/// §8.2. The two rates `afterTaxLiquidNetWorth` prices a balance with.
///
/// The naive approach, guessing a FIRE number and running the whole
/// multi-decade decumulation against it until it converges, is accurate and
/// expensive: it reruns years of simulation at every candidate year. Instead
/// both rates come **directly from that year's actual balances**, by sourcing
/// exactly one year of spending through the configured `withdrawalOrder` and
/// running that single draw through the real §4.3 computation.
///
/// This prices the *first* year of retirement accurately and does not capture
/// how the picture shifts decades in, with RMDs forcing more ordinary income
/// later. Leg 3's full simulation is what catches an over-optimistic estimate.
library;

import '../entities/assumptions.dart';
import '../entities/household.dart';
import '../loop/account_state.dart';
import '../loop/withdrawals.dart';
import '../pipeline/federal_tax.dart';
import '../pipeline/income_tax.dart';
import '../pipeline/wages.dart';
import '../taxyear/tax_year.dart';
import '../types.dart';

class EmbeddedRates {
  /// The marginal rate a further dollar of tax-deferred money would pay.
  final Rate effectiveRetirementTaxRate;

  /// The marginal rate a further dollar of long-term gain would pay, given
  /// where the household's ordinary income already sits (§4.3.3).
  final Rate projectedLtcgRate;

  /// What the one-year draw actually reached, which is what makes the rates
  /// specific to this household rather than an assumption.
  final Money ordinaryDrawn;
  final Money gainsDrawn;

  const EmbeddedRates({
    required this.effectiveRetirementTaxRate,
    required this.projectedLtcgRate,
    required this.ordinaryDrawn,
    required this.gainsDrawn,
  });
}

/// §8.2, at one candidate year.
///
/// [balances] are read, never written: the draw runs against copies, since this
/// is an estimate and not a movement of money.
EmbeddedRates deriveEmbeddedRates({
  required Household household,
  required Map<Id, Money> balances,
  required Map<Id, Money> costBases,
  required Map<Id, Money> rothBases,
  required Assumptions assumptions,
  required TaxYear taxYear,
  required Map<Id, AssetClass> assetClasses,
  required Money retirementAnnualExpenses,
  required int year,
  required int currentYear,
}) {
  Map<Id, AccountState> snapshot() {
    final states = <Id, AccountState>{};
    for (final account in household.accounts) {
      final state = AccountState(account)
        ..balance = balances[account.id] ?? account.balance
        ..costBasis = costBases[account.id] ?? account.costBasis
        ..rothContributionBasis =
            rothBases[account.id] ?? account.rothContributionBasis;
      states[account.id] = state;
    }
    return states;
  }

  final draw = sourceGap(
    retirementAnnualExpenses,
    household: household,
    accounts: snapshot(),
    assumptions: assumptions,
    taxYear: taxYear,
    year: year,
    annualExpenses: retirementAnnualExpenses,
  );

  // A probe large enough to cross a bracket boundary if one is near, and small
  // enough that the answer is still a marginal rate rather than an average.
  final probe = maxMoney(retirementAnnualExpenses * 0.10, Money.dollars(1000));

  Money taxWith({Money extraOrdinary = Money.zero, Money extraGains = Money.zero}) {
    final unit = household.taxUnits.first;
    final wages = [
      for (final person in household.people)
        computeWages(person,
            household: household,
            taxYear: taxYear,
            year: year,
            currentYear: currentYear),
    ];
    final inputs = YearInputs(
      rmdIncome: draw.ordinaryIncome + extraOrdinary,
      realizedGainsOnDraws: draw.realizedGains + extraGains,
    );
    final income = computeTaxableIncome(unit,
        household: household,
        assumptions: assumptions,
        taxYear: taxYear,
        assetClasses: assetClasses,
        wages: wages,
        year: year,
        currentYear: currentYear,
        inputs: inputs);
    final owed = computeTaxOwed(unit,
        household: household,
        income: income,
        wages: wages,
        assumptions: assumptions,
        taxYear: taxYear,
        year: year,
        currentYear: currentYear,
        inputs: inputs);
    return owed.federalTax + owed.stateTax + owed.localTax;
  }

  final base = taxWith();
  final withOrdinary = taxWith(extraOrdinary: probe);
  final withGains = taxWith(extraGains: probe);

  return EmbeddedRates(
    effectiveRetirementTaxRate:
        (withOrdinary - base).ratioTo(probe).clamp(0.0, 1.0),
    projectedLtcgRate: (withGains - base).ratioTo(probe).clamp(0.0, 1.0),
    ordinaryDrawn: draw.ordinaryIncome,
    gainsDrawn: draw.realizedGains,
  );
}
