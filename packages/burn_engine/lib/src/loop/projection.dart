/// §6. The projection engine: one loop, from `currentYear` to the horizon.
///
/// There is one loop, and the sign of `netSurplus` decides how it ends. A
/// working year has money to allocate and a retired year has a gap to fill;
/// nothing else about the year differs, so growth, asset sales, amortisation,
/// basis and the net-worth measures are written once. A Barista FIRE year
/// holding both wages and withdrawals needs no special case, and neither does
/// a working year that runs short.
library;

import 'dart:math' as math;

import '../entities/assumptions.dart';
import '../entities/household.dart';
import '../pipeline/income_tax.dart';
import '../pipeline/year.dart';
import '../pipeline/allocation.dart';
import '../taxyear/tax_year.dart';
import '../types.dart';
import 'account_state.dart';
import 'amortization.dart';
import 'measures.dart';
import 'waterfall.dart';
import 'withdrawals.dart';

/// One projected year, as the loop emits it.
class ProjectedYear {
  final int year;
  final double frac;
  final YearResult solved;
  final NetWorth netWorth;
  final Money contributed;
  final Money employerMatch;
  final Money drawn;
  final Map<Id, Money> accountBalances;
  final Set<String> flags;

  const ProjectedYear({
    required this.year,
    required this.frac,
    required this.solved,
    required this.netWorth,
    required this.contributed,
    required this.employerMatch,
    required this.drawn,
    required this.accountBalances,
    required this.flags,
  });

  Money get netSurplus => solved.netSurplus;
}

class Projection {
  final List<ProjectedYear> years;
  final BandName band;

  const Projection({required this.years, required this.band});

  ProjectedYear? yearOf(int year) =>
      years.where((y) => y.year == year).firstOrNull;
}

/// §6, for one band.
///
/// [retirementYear] is handed in: solving for it is §8.2's job, and it runs
/// this loop repeatedly to do so.
Projection project(
  Household household, {
  required Assumptions assumptions,
  required TaxYear taxYear,
  required Map<Id, AssetClass> assetClasses,
  required DateTime asOfDate,
  required int? retirementYear,
  BandName band = BandName.expected,
  Rate projectedLtcgRate = 0.15,
  Rate effectiveRetirementTaxRate = 0.15,
}) {
  final currentYear = asOfDate.year;
  final horizon = _horizon(household, assumptions, currentYear);

  final accounts = {
    for (final a in household.accounts) a.id: AccountState(a),
  };
  final liabilities = {
    for (final l in household.liabilities) l.id: LiabilityState(l),
  };
  final assetValues = {
    for (final a in household.assets) a.id: a.currentValue,
  };
  final depreciation = {
    for (final a in household.assets) a.id: a.accumulatedDepreciation,
  };

  final years = <ProjectedYear>[];

  for (var year = currentYear; year <= horizon; year++) {
    final frac = year == currentYear ? _yearFraction(asOfDate) : 1.0;
    final flags = <String>{};

    // Assets appreciate and rentals depreciate before anything reads them.
    for (final asset in household.assets) {
      if (!asset.heldIn(year)) continue;
      if (year > currentYear || asset.acquisitionYear == year) {
        assetValues[asset.id] = assetValues[asset.id]! *
            math.pow(1 + asset.realAppreciationRate, frac);
      }
      depreciation[asset.id] = depreciation[asset.id]! +
          annualDepreciationFor(asset,
              residentialDepreciationYears:
                  taxYear.residentialDepreciationYears);
    }

    // Settle this year's asset purchases and sales, fixing the money and gains
    // they move (§3.5).
    var assetSaleGain = Money.zero;
    var assetSaleRecapture = Money.zero;
    for (final asset in household.assets) {
      if (asset.acquisitionYear == year) {
        final mortgage = asset.securedByLiabilityId == null
            ? Money.zero
            : liabilities[asset.securedByLiabilityId]?.balance ?? Money.zero;
        final downPayment = (asset.costBasis - mortgage).orZeroIfNegative;
        final funding = accounts[asset.purchaseFundingAccountId];
        if (funding != null && downPayment.isPositive) {
          final taken = funding.withdraw(downPayment);
          if (taken < downPayment) flags.add('shortfall');
        }
        assetValues[asset.id] = asset.costBasis;
      }
      if (asset.plannedSaleYear == year) {
        final secured = asset.securedByLiabilityId == null
            ? Money.zero
            : liabilities[asset.securedByLiabilityId]?.balance ?? Money.zero;
        final sale = computeAssetSale(
          asset,
          projectedValue: assetValues[asset.id]!,
          assumptions: assumptions,
          section121Exclusion: taxYear
              .section121Exclusion[household.taxUnits.first.filingStatus]!
              .value,
          unrecapturedRate: taxYear.unrecapturedSection1250Rate,
          securedBalance: secured,
        );
        assetSaleGain += sale.taxableGain;
        assetSaleRecapture += sale.recapture;
        if (asset.securedByLiabilityId != null) {
          final debt = liabilities[asset.securedByLiabilityId];
          if (debt != null) {
            debt.balance = Money.zero;
            debt.paidOff = true;
          }
        }
        if (sale.underwater) {
          flags.add('shortfall');
        } else {
          accounts[asset.saleProceedsAccountId]
              ?.deposit(sale.netProceeds);
        }
      }
    }

    // RMDs come off the top of the year, as cash in hand before it is priced.
    final rmds = requiredMinimumDistributions(
      household: household,
      accounts: accounts,
      taxYear: taxYear,
      year: year,
    );
    final rmdTotal = sumMoney(rmds.values);

    // Settle one-time events that name an account.
    for (final event in household.oneTimeEvents.where((e) => e.year == year)) {
      final account = accounts[event.accountId];
      if (account == null) continue;
      if (event.isOutflow) {
        final taken = account.withdraw(-event.amount);
        if (taken < -event.amount) flags.add('shortfall');
      } else {
        account.deposit(event.amount);
      }
    }

    // §4.1 onward on FULL-YEAR figures, with the fixed point solved.
    var solved = solveYear(
      household,
      assumptions: assumptions,
      taxYear: taxYear,
      assetClasses: assetClasses,
      year: year,
      currentYear: currentYear,
      retirementYear: retirementYear,
      inputs: YearInputs(
        rmdIncome: rmdTotal,
        assetSaleTaxableGain: assetSaleGain,
        assetSaleRecapture: assetSaleRecapture,
        annualDepreciation: sumMoney(household.assets
            .where((a) => a.heldIn(year))
            .map((a) => annualDepreciationFor(a,
                residentialDepreciationYears:
                    taxYear.residentialDepreciationYears))),
        studentLoanInterestPaid: sumMoney(liabilities.values
            .where((l) => l.liability.isTaxDeductibleInterest)
            .map((l) => l.interestPaidThisYear)),
      ),
    );
    if (solved.waterfallNotConverged) flags.add('waterfallNotConverged');

    // Apply the committed contributions and their employer match to balances.
    var contributed = Money.zero;
    var matched = Money.zero;
    final alreadyContributed = <Id, Money>{};
    for (final c in solved.contributions) {
      final state = accounts[c.accountId];
      if (state == null) continue;
      state.contribute(c.employee * frac);
      state.creditEmployerMatch(c.employerMatch * frac);
      contributed += c.employee * frac;
      matched += c.employerMatch * frac;
      alreadyContributed[c.accountId] = c.employee * frac;
      if (c.limitExceeded) flags.add('contributionLimitExceeded');
    }

    // Distributions are taxed this year and stay in the account, so they raise
    // basis without moving the balance (§4.3.1, §6.3). Without this the same
    // dollars would be taxed again as gains on the way out.
    for (final state in accounts.values.where((a) => a.isTaxable)) {
      state.creditInvestmentIncome(
          state.balance * blendedIncomeYield(state.account, assetClasses));
    }

    final earnedIncome = {
      for (final w in solved.wages)
        w.personId: w.wageIncome + w.seEarnings,
    };
    final annualExpenses = solved.cashFlow.annualExpenses;

    var drawn = Money.zero;
    if (solved.netSurplus.isNegative) {
      // The drawdown carries a fixed point of its own: a traditional draw is
      // ordinary income, that income is taxed, and the tax has to be drawn as
      // well, which raises the draw again (§6).
      var gap = -solved.netSurplus;
      for (var pass = 0; pass < 3; pass++) {
        final draw = sourceGap(
          gap,
          household: household,
          accounts: accounts,
          assumptions: assumptions,
          taxYear: taxYear,
          year: year,
          annualExpenses: annualExpenses,
        );
        drawn += draw.total;
        if (draw.shortfall) flags.add('shortfall');
        if (draw.bufferDepleted) flags.add('bufferDepleted');

        final repriced = solveYear(
          household,
          assumptions: assumptions,
          taxYear: taxYear,
          assetClasses: assetClasses,
          year: year,
          currentYear: currentYear,
          retirementYear: retirementYear,
          inputs: YearInputs(
            rmdIncome: rmdTotal + draw.ordinaryIncome,
            realizedGainsOnDraws: draw.realizedGains,
            assetSaleTaxableGain: assetSaleGain,
            assetSaleRecapture: assetSaleRecapture,
          ),
          penalties: draw.penalties,
        );
        final extra = (repriced.totalTaxOwed - solved.totalTaxOwed)
            .orZeroIfNegative;
        solved = repriced;
        if (!extra.isPositive) break;
        gap = extra;
      }
    } else {
      // A surplus year: run the waterfall against balances and principal.
      final allocation = runAllocationSweep(
        household,
        assumptions: assumptions,
        taxYear: taxYear,
        accounts: accounts,
        liabilities: liabilities,
        alreadyContributed: alreadyContributed,
        earnedIncome: earnedIncome,
        surplus: solved.netSurplus * frac,
        annualExpenses: annualExpenses,
        year: year,
        currentYear: currentYear,
      );
      allocation.toAccounts.forEach((id, amount) {
        accounts[id]?.contribute(amount);
      });
      // Realise gains per the scenario rate, in surplus years only (§6.3).
      for (final state in accounts.values.where((a) => a.isTaxable)) {
        state.realizeGains(assumptions.capitalGainsRealizationRate);
      }
      for (final entry in allocation.toDebt.entries) {
        final debt = liabilities[entry.key];
        if (debt == null) continue;
        debt.balance = (debt.balance - entry.value).orZeroIfNegative;
        if (!debt.balance.isPositive) debt.paidOff = true;
      }
    }

    // Growth, then amortisation, then the measures.
    for (final state in accounts.values) {
      state.grow(assetClasses: assetClasses, band: band, frac: frac);
    }
    for (final debt in liabilities.values) {
      debt.advanceYear(
        asOfDate: asOfDate,
        assumptions: assumptions,
        frac: frac,
        securingAssetBasis: _securedAssetBasis(household, debt),
      );
    }

    years.add(ProjectedYear(
      year: year,
      frac: frac,
      solved: solved,
      netWorth: computeNetWorth(
        household: household,
        accounts: accounts,
        liabilities: liabilities,
        assetValues: assetValues,
        assumptions: assumptions,
        annualExpenses: annualExpenses,
        year: year,
        projectedLtcgRate: projectedLtcgRate,
        effectiveRetirementTaxRate: effectiveRetirementTaxRate,
      ),
      contributed: contributed,
      employerMatch: matched,
      drawn: drawn,
      accountBalances: {
        for (final e in accounts.entries) e.key: e.value.balance,
      },
      flags: flags,
    ));
  }

  return Projection(years: years, band: band);
}

/// The year the youngest person reaches `projectionHorizonAge`, so the
/// portfolio has to outlast whoever will need it longest (§8.2).
int _horizon(Household household, Assumptions assumptions, int currentYear) {
  if (household.people.isEmpty) return currentYear;
  final youngest = household.people
      .map((p) => p.birthDate.year)
      .reduce((a, b) => a > b ? a : b);
  return youngest + assumptions.projectionHorizonAge;
}

/// The remaining fraction of the calendar year from [asOfDate] to 31 December.
double _yearFraction(DateTime asOfDate) {
  final endOfYear = DateTime(asOfDate.year + 1, 1, 1);
  final startOfYear = DateTime(asOfDate.year, 1, 1);
  final total = endOfYear.difference(startOfYear).inDays;
  final remaining = endOfYear.difference(asOfDate).inDays;
  return remaining / total;
}

Money? _securedAssetBasis(Household household, LiabilityState debt) {
  final id = debt.liability.securedAssetId;
  if (id == null) return null;
  final asset = household.assets.where((a) => a.id == id).firstOrNull;
  return asset?.costBasis;
}
