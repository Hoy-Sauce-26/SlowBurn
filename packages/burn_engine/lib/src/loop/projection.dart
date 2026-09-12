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
import '../entities/retirement_defaults.dart';
import '../pipeline/income_tax.dart';
import '../pipeline/year.dart';
import '../pipeline/allocation.dart';
import '../taxyear/tax_year.dart';
import '../enums.dart';
import '../types.dart';
import 'account_state.dart';
import 'amortization.dart';
import '../solve/embedded_rates.dart';
import 'flags.dart';
import 'measures.dart';
import 'waterfall.dart';
import 'withdrawals.dart';

/// One projected year, as the loop emits it.
class ProjectedYear {
  final int year;
  final double frac;
  final YearResult solved;

  /// §8.2's two rates as this year's balances priced them.
  final EmbeddedRates embeddedRates;

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
    required this.embeddedRates,
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
  /// Overrides the per-year derivation, for tests that want a fixed rate.
  Rate? projectedLtcgRate,
  Rate? effectiveRetirementTaxRate,
}) {
  final currentYear = asOfDate.year;
  final horizon = horizonYear(household, assumptions, currentYear);

  // §3.3: earned income, payroll deferrals and payroll deductions end with the
  // job unless somebody said otherwise. That is a default rather than a stored
  // value, so it is resolved here, once, before anything reads a span.
  household = withRetirementDefaults(household, retirementYear);

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

  Money restrictedBalance() => sumMoney(accounts.values
      .where((a) => a.account.isRestrictedPurpose)
      .map((a) => a.balance));

  // The last year anything is spent on education, after which a 529 has
  // nothing to pay for. Null while some of it runs on with no end.
  final meta = {
    for (final c in household.expenseCategories) c.id: c.metaCategory
  };
  final education = household.expenseItems
      .where((i) => meta[i.categoryId] == MetaCategory.education)
      .toList();
  final lastTuition = education.isEmpty
      ? currentYear - 1
      : education.any((i) => i.endYear == null)
          ? null
          : education.map((i) => i.endYear!).reduce(math.max);

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

    // §8.4.1's assumed rollover. A designated Roth balance is unreachable as
    // basis until it moves, so at the person's retirement year the engine moves
    // it into their Roth IRA, creating one if absent, and says it did.
    if (retirementYear != null && year == retirementYear) {
      for (final person in household.people) {
        final designated = household
            .accountsFor(person.id)
            .where((a) =>
                a.taxTreatment == TaxTreatment.roth &&
                a.limitFamily == LimitFamily.electiveDeferral)
            .toList();
        if (designated.isEmpty) continue;
        final target = household
            .accountsFor(person.id)
            .where((a) => a.kind == AccountKind.rothIra)
            .map((a) => accounts[a.id])
            .whereType<AccountState>()
            .firstOrNull;
        if (target == null) continue;
        for (final source in designated) {
          final from = accounts[source.id];
          if (from == null || !from.balance.isPositive) continue;
          final movedBasis = from.rothContributionBasis;
          final moved = from.balance;
          from.balance = Money.zero;
          from.rothContributionBasis = Money.zero;
          target.balance += moved;
          target.rothContributionBasis += movedBasis;
          flags.add('rothRolloverAssumed');
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

    // Sweep 1 lands before §4.1: hsaPayrollToLimit is the one step that reduces
    // FICA wages, and an election settled later would miss ficaExempt and
    // overstate payroll tax for the whole accumulation phase (§4.4.2).
    final projectedEarned = {
      for (final person in household.people)
        person.id: sumMoney(household
            .streamsFor(person.id)
            .where((s) => s.kind.isEarned)
            .map((s) => s.resolvedAmount(year, currentYear: currentYear))),
    };
    final election = runElectionSweep(
      household,
      assumptions: assumptions,
      taxYear: taxYear,
      accounts: accounts,
      liabilities: liabilities,
      earnedIncome: projectedEarned,
      projectedSurplus: _projectedSurplus(
        household, projectedEarned, year, currentYear, retirementYear),
      annualExpenses: Money.zero,
      year: year,
    );

    // §4.1 onward on FULL-YEAR figures, with the fixed point solved.
    var solved = solveYear(
      household,
      assumptions: assumptions,
      taxYear: taxYear,
      assetClasses: assetClasses,
      year: year,
      currentYear: currentYear,
      retirementYear: retirementYear,
      proposedContributions: election.toAccounts,
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
        restrictedBalance: restrictedBalance(),
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

    // From the retirement year on, an account holds whatever it was going to
    // be moved into, and a 529 from the year its tuition starts. A portfolio
    // that carries somebody to retirement is rarely the one they live off
    // afterwards (§3.9).
    bool moved(AccountState s) =>
        household.movedIn(s.account, year, retirementYear: retirementYear);

    // Distributions are taxed this year and stay in the account, so they raise
    // basis without moving the balance (§4.3.1, §6.3). Without this the same
    // dollars would be taxed again as gains on the way out.
    for (final state in accounts.values.where((a) => a.isTaxable)) {
      state.creditInvestmentIncome(state.balance *
          blendedIncomeYield(state.account, assetClasses,
              retired: moved(state)));
    }

    final earnedIncome = {
      for (final w in solved.wages)
        w.personId: w.wageIncome + w.seEarnings,
    };
    final annualExpenses = solved.cashFlow.annualExpenses;

    // Money already withheld from a paycheck against a year that turned out
    // not to support it. A payrollElection is never unwound, since a deferral
    // already taken cannot be undone at year end, so the year runs short and
    // draws the buffer instead. That is what happens to a real household that
    // set its deferral too high, and it is visible rather than quietly
    // smoothed away (§4.4.4). It covers the user's own committed deferral as
    // well as sweep 1's election, since both are withheld the same way.
    final withheld = sumMoney(solved.contributions.where((c) {
      final account = household.accountById(c.accountId);
      if (account == null) return false;
      return account.limitFamily == LimitFamily.electiveDeferral ||
          account.limitFamily == LimitFamily.simpleDeferral ||
          (account.limitFamily == LimitFamily.hsa &&
              account.contribution.reducesFicaWages);
    }).map((c) => c.employee));
    if (withheld.isPositive && solved.netSurplus.isNegative) {
      flags.add('electionExceededRealizedSurplus');
    }

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
          magiHeadroom: magiCeilingFor(
            household: household,
            assumptions: assumptions,
            taxYear: taxYear,
            magiSoFar: sumMoney(solved.incomes.map((i) => i.federalAgi)),
            year: year,
          ),
        );
        drawn += draw.total;
        if (draw.shortfall) flags.add('shortfall');
        if (draw.bufferDepleted) flags.add('bufferDepleted');
        // An RMD can breach it involuntarily, which is the point of the flag.
        if (draw.magiCeilingBreached) flags.add('magiCeilingBreached');

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
            restrictedBalance: restrictedBalance(),
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

    // The tuition the 529s paid comes out of them, in proportion to what each
    // holds. Left in, the same balance would pay every year's tuition (§4.4).
    final paid = solved.cashFlow.education529Draw * frac;
    final held = restrictedBalance();
    if (paid.isPositive && held.isPositive) {
      for (final state
          in accounts.values.where((a) => a.account.isRestrictedPurpose)) {
        state.withdraw(paid * state.balance.ratioTo(held));
      }
    }
    // Said once, the first year there is nothing left for it to pay. Taken out
    // for anything else, its growth is taxed and penalised.
    if (lastTuition != null &&
        year == math.max(lastTuition + 1, currentYear) &&
        restrictedBalance() > Money.dollars(1000)) {
      flags.add('education529LeftOver');
    }

    // Growth, then amortisation, then the measures.
    for (final state in accounts.values) {
      state.grow(
          assetClasses: assetClasses,
          band: band,
          frac: frac,
          retired: moved(state));
    }
    for (final debt in liabilities.values) {
      debt.advanceYear(
        asOfDate: asOfDate,
        assumptions: assumptions,
        frac: frac,
        securingAssetBasis: _securedAssetBasis(household, debt),
      );
    }

    // §8.2's two rates, from this year's actual balances rather than an
    // assumption. Derived after the year is solved, since the draw they price
    // is one year of this household's own cost of living.
    final rates = deriveEmbeddedRates(
      household: household,
      balances: {for (final e in accounts.entries) e.key: e.value.balance},
      costBases: {for (final e in accounts.entries) e.key: e.value.costBasis},
      rothBases: {
        for (final e in accounts.entries) e.key: e.value.rothContributionBasis
      },
      assumptions: assumptions,
      taxYear: taxYear,
      assetClasses: assetClasses,
      retirementAnnualExpenses: solved.cashFlow.expensesFromLiquid,
      year: year,
      currentYear: currentYear,
    );

    flags.addAll(yearFlags(
      household: household,
      assumptions: assumptions,
      taxYear: taxYear,
      wages: solved.wages,
      incomes: solved.incomes,
      owed: solved.owed,
      contributions: solved.contributions,
      liabilities: liabilities,
      asOfDate: asOfDate,
      year: year,
      retirementYear: retirementYear,
    ));
    flags.addAll(doubleCountFlags(household));
    if (retirementYear != null &&
        swrHorizonMismatch(assumptions, horizon - retirementYear + 1)) {
      flags.add('swrHorizonMismatch');
    }

    years.add(ProjectedYear(
      year: year,
      frac: frac,
      solved: solved,
      embeddedRates: rates,
      netWorth: computeNetWorth(
        household: household,
        accounts: accounts,
        liabilities: liabilities,
        assetValues: assetValues,
        assumptions: assumptions,
        annualExpenses: annualExpenses,
        year: year,
        projectedLtcgRate: projectedLtcgRate ?? rates.projectedLtcgRate,
        effectiveRetirementTaxRate:
            effectiveRetirementTaxRate ?? rates.effectiveRetirementTaxRate,
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
/// What sweep 1 has to guess at, since it runs before the year is priced: pay
/// less a rough allowance for tax, less this year's living costs.
///
/// Deliberately conservative. An election is withheld from a paycheck and
/// cannot be handed back, so guessing low costs the household some tax-advantaged
/// room it could have used, and guessing high costs it a shortfall it cannot
/// undo. §4.4.3's fixed point then prices whatever was elected exactly.
Money _projectedSurplus(
  Household household,
  Map<Id, Money> earned,
  int year,
  int currentYear,
  int? retirementYear,
) {
  final pay = sumMoney(earned.values);
  final expenses = sumMoney(household.expenseItems.map((i) => i.amountIn(
        year,
        currentYear: currentYear,
        retirementYear: retirementYear,
        categoryDefaultInflation: 0,
      )));
  return (pay * 0.70 - expenses).orZeroIfNegative;
}

int horizonYear(Household household, Assumptions assumptions, int currentYear) {
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
