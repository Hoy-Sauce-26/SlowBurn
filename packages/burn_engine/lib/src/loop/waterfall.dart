/// §4.4.4. Where a year's surplus goes, in the order the user chose.
///
/// A **household-level** list of step categories, so each step sweeps every
/// eligible account across every person at once rather than exhausting one
/// person's accounts before considering another's.
library;

import '../entities/assumptions.dart';
import '../entities/household.dart';
import '../enums.dart';
import '../pipeline/limits.dart';
import '../taxyear/tax_year.dart';
import '../types.dart';
import 'account_state.dart';
import 'amortization.dart';

/// What one sweep decided to do with the money it was given.
class Allocation {
  /// Employee dollars per account.
  final Map<Id, Money> toAccounts;

  /// Principal paydown per liability.
  final Map<Id, Money> toDebt;

  final Money spent;
  final Money remaining;

  /// A step wanted more than the surplus could fund.
  final bool anyStepPartiallyFunded;

  const Allocation({
    required this.toAccounts,
    required this.toDebt,
    required this.spent,
    required this.remaining,
    required this.anyStepPartiallyFunded,
  });
}

/// §4.4.2's sweep 2: allocate realised surplus across the `filingDeadline` and
/// `anytime` steps.
///
/// [alreadyContributed] is what the committed contributions already put in this
/// year. Each step's capacity is the account's **remaining room**, so a user
/// contributing 10% to a 401(k) does not get that subtracted and then the
/// account topped up to the full limit again (§4.4.1).
Allocation runAllocationSweep(
  Household household, {
  required Assumptions assumptions,
  required TaxYear taxYear,
  required Map<Id, AccountState> accounts,
  required Map<Id, LiabilityState> liabilities,
  required Map<Id, Money> alreadyContributed,
  required Map<Id, Money> earnedIncome,
  required Money surplus,
  required Money annualExpenses,
  required int year,
  required int currentYear,
}) =>
    _sweep(
      household,
      assumptions: assumptions,
      taxYear: taxYear,
      accounts: accounts,
      liabilities: liabilities,
      alreadyContributed: alreadyContributed,
      earnedIncome: earnedIncome,
      surplus: surplus,
      annualExpenses: annualExpenses,
      year: year,
      windows: const {FundingWindow.filingDeadline, FundingWindow.anytime},
    );

/// §4.4.2's sweep 1: settle payroll elections before §4.1, reserving first for
/// anything the user ranked **above** a payroll step.
///
/// The reservation is what makes the ordering mean something despite the timing
/// difference: ranking `highInterestDebt` above the 401(k) is how a user says
/// "pay the credit card before maxing the plan", and without it the payroll
/// step would take the money first simply because it resolves earlier.
Allocation runElectionSweep(
  Household household, {
  required Assumptions assumptions,
  required TaxYear taxYear,
  required Map<Id, AccountState> accounts,
  required Map<Id, LiabilityState> liabilities,
  required Map<Id, Money> earnedIncome,
  required Money projectedSurplus,
  required Money annualExpenses,
  required int year,
}) {
  final order = assumptions.contributionWaterfall;
  final firstPayroll =
      order.indexWhere((s) => s.window == FundingWindow.payrollElection);

  var available = projectedSurplus;
  if (firstPayroll > 0) {
    final ranked = order
        .take(firstPayroll)
        .where((s) => s.window != FundingWindow.payrollElection)
        .toSet();
    if (ranked.isNotEmpty) {
      final reserved = _sweep(
        household,
        assumptions: assumptions,
        taxYear: taxYear,
        accounts: accounts,
        liabilities: liabilities,
        alreadyContributed: const {},
        earnedIncome: earnedIncome,
        surplus: projectedSurplus,
        annualExpenses: annualExpenses,
        year: year,
        windows: const {FundingWindow.filingDeadline, FundingWindow.anytime},
        only: ranked,
      );
      available = reserved.remaining;
    }
  }

  return _sweep(
    household,
    assumptions: assumptions,
    taxYear: taxYear,
    accounts: accounts,
    liabilities: liabilities,
    alreadyContributed: const {},
    earnedIncome: earnedIncome,
    surplus: available,
    annualExpenses: annualExpenses,
    year: year,
    windows: const {FundingWindow.payrollElection},
  );
}

Allocation _sweep(
  Household household, {
  required Assumptions assumptions,
  required TaxYear taxYear,
  required Map<Id, AccountState> accounts,
  required Map<Id, LiabilityState> liabilities,
  required Map<Id, Money> alreadyContributed,
  required Map<Id, Money> earnedIncome,
  required Money surplus,
  required Money annualExpenses,
  required int year,
  required Set<FundingWindow> windows,
  Set<WaterfallStep>? only,
}) {
  final toAccounts = <Id, Money>{};
  final toDebt = <Id, Money>{};
  var remaining = surplus.orZeroIfNegative;
  var partial = false;

  for (final step in assumptions.contributionWaterfall) {
    if (!windows.contains(step.window)) continue;
    if (only != null && !only.contains(step)) continue;
    if (!remaining.isPositive) break;

    if (step == WaterfallStep.highInterestDebt) {
      // Highest real rate first: clearing a 22% card before a 7% student loan
      // is strictly better, so this step overrides the pro-rata rule.
      final targets = liabilities.values
          .where((l) =>
              !l.paidOff &&
              _realRate(l, assumptions) >
                  assumptions.highInterestDebtThresholdRate)
          .toList()
        ..sort((a, b) =>
            _realRate(b, assumptions).compareTo(_realRate(a, assumptions)));
      for (final l in targets) {
        if (!remaining.isPositive) break;
        final pay = minMoney(remaining, l.balance);
        toDebt[l.id] = (toDebt[l.id] ?? Money.zero) + pay;
        remaining -= pay;
      }
      continue;
    }

    // Every retirement-account step needs earned income behind it: elective
    // deferrals come out of pay, and IRA and HSA contributions require
    // compensation (§4.4.1).
    final room = <Id, Money>{};
    for (final person in household.people) {
      if (step.requiresEarnedIncome &&
          !(earnedIncome[person.id] ?? Money.zero).isPositive) {
        continue;
      }
      final cap = familyCap(
        _familyFor(step),
        taxYear: taxYear,
        age: person.ageIn(year),
        hsaTier: person.hsaTierIn(year),
      );
      for (final account in household.accountsFor(person.id)) {
        if (!_stepAccepts(step, account.kind, account.limitFamily)) continue;
        final state = accounts[account.id];
        if (state == null) continue;

        final gap = step == WaterfallStep.cashBufferToTarget
            ? _bufferGap(state, annualExpenses)
            : (isUnbounded(cap)
                ? remaining
                : (cap - (alreadyContributed[account.id] ?? Money.zero))
                    .orZeroIfNegative);
        if (gap.isPositive) room[account.id] = gap;
      }
    }

    if (room.isEmpty) continue;
    final wanted = sumMoney(room.values);
    if (wanted <= remaining) {
      room.forEach((id, amount) {
        toAccounts[id] = (toAccounts[id] ?? Money.zero) + amount;
      });
      remaining -= wanted;
    } else {
      // Split pro rata by remaining room, which keeps the waterfall a flat list
      // without an explicit priority order between people (§4.4.4).
      partial = true;
      room.forEach((id, amount) {
        final share = remaining * amount.ratioTo(wanted);
        toAccounts[id] = (toAccounts[id] ?? Money.zero) + share;
      });
      remaining = Money.zero;
    }
  }

  return Allocation(
    toAccounts: toAccounts,
    toDebt: toDebt,
    spent: surplus.orZeroIfNegative - remaining,
    remaining: remaining,
    anyStepPartiallyFunded: partial,
  );
}

/// §4.5. How far a cash-buffer account is below its target this year.
Money _bufferGap(AccountState state, Money annualExpenses) {
  final months = state.account.targetBalanceMonths;
  if (months == null) return Money.zero;
  final target = annualExpenses * (months / 12);
  return (target - state.balance).orZeroIfNegative;
}

/// Real so it compares like-for-like against real returns: paying down debt is
/// an investment decision and both sides need the same units (§3.9).
Rate _realRate(LiabilityState l, Assumptions a) =>
    (1 + l.liability.interestRate) / (1 + a.generalInflationRate) - 1;

LimitFamily _familyFor(WaterfallStep step) => switch (step) {
      WaterfallStep.matchCapture ||
      WaterfallStep.electiveDeferralToLimit =>
        LimitFamily.electiveDeferral,
      WaterfallStep.hsaPayrollToLimit ||
      WaterfallStep.hsaDirectToLimit =>
        LimitFamily.hsa,
      WaterfallStep.iraToLimit => LimitFamily.ira,
      _ => LimitFamily.none,
    };

bool _stepAccepts(WaterfallStep step, AccountKind kind, LimitFamily family) =>
    switch (step) {
      WaterfallStep.matchCapture ||
      WaterfallStep.electiveDeferralToLimit =>
        family == LimitFamily.electiveDeferral ||
            family == LimitFamily.simpleDeferral,
      WaterfallStep.hsaPayrollToLimit ||
      WaterfallStep.hsaDirectToLimit =>
        family == LimitFamily.hsa,
      WaterfallStep.iraToLimit => family == LimitFamily.ira,
      WaterfallStep.cashBufferToTarget =>
        kind == AccountKind.cashSavings || kind == AccountKind.cashChecking,
      WaterfallStep.taxableBrokerage => kind == AccountKind.taxableBrokerage,
      WaterfallStep.highInterestDebt => false,
    };
