/// §8.4.1 and §8.4.2. Where a shortfall is sourced from, and what it costs.
///
/// The sources are ordered by **tax character**, not by account: one draw may
/// touch several accounts of the same character, and the order decides how much
/// tax and penalty the year owes.
library;

import '../entities/assumptions.dart';
import '../entities/household.dart';
import '../entities/person.dart';
import '../enums.dart';
import '../pipeline/federal_tax.dart';
import '../taxyear/tax_year.dart';
import '../types.dart';
import 'account_state.dart';

/// What a year's draw took, and the tax character of it.
class Draw {
  final Money total;

  /// MAGI-counting ordinary income the draw created (§4.3.1).
  final Money ordinaryIncome;

  /// The gain half of a taxable draw, which is preferential (§8.4.1).
  final Money realizedGains;

  /// Penalties, per tax unit (§4.3.6).
  final Map<Id, WithdrawalPenalties> penalties;

  /// The gap could not be met from any source.
  final bool shortfall;

  /// A cash buffer was drawn below its target (§4.5).
  final bool bufferDepleted;

  /// The MAGI ceiling had to be crossed to fund the year (§8.4.4).
  final bool magiCeilingBreached;

  const Draw({
    required this.total,
    required this.ordinaryIncome,
    required this.realizedGains,
    required this.penalties,
    required this.shortfall,
    required this.bufferDepleted,
    this.magiCeilingBreached = false,
  });
}

/// §8.4.4. How much MAGI-counting income a draw may create before it costs the
/// household its premium tax credit.
///
/// Rather than solving jointly for the withdrawal mix that maximises lifetime
/// after-tax-and-premium spending, a real optimisation problem (§13.3), the
/// configured order becomes a heuristic ceiling. Null means no ceiling applies:
/// nobody in the household is buying their own pre-65 coverage.
Money? magiCeilingFor({
  required Household household,
  required Assumptions assumptions,
  required TaxYear taxYear,
  required Money magiSoFar,
  required int year,
}) {
  var anyCovered = false;
  var ceiling = Money.zero;
  for (final unit in household.taxUnits) {
    final people = household.peopleIn(unit).toList();
    final covered = people.where((p) =>
        p.ageIn(year) < 65 &&
        year > (p.employerHealthCoverageEndYear ?? -1 << 31));
    if (covered.isEmpty) continue;
    anyCovered = true;
    final size = people.length + unit.activeDependents(year).length;
    final poverty = taxYear.povertyLevel(unit.stateCode, size);
    ceiling += poverty * assumptions.acaMagiCeilingPercentOfFpl;
  }
  if (!anyCovered) return null;
  return (ceiling - magiSoFar).orZeroIfNegative;
}

/// §8.4.1. Source [gap] through the scenario's withdrawal order.
///
/// Mutates the account states, since a draw is a real movement of money.
Draw sourceGap(
  Money gap, {
  required Household household,
  required Map<Id, AccountState> accounts,
  required Assumptions assumptions,
  required TaxYear taxYear,
  required int year,
  required Money annualExpenses,
  /// §8.4.4. How much MAGI-counting income this draw may create before the
  /// premium tax credit starts to cost more than the draw is worth. Null means
  /// no ceiling applies.
  Money? magiHeadroom,
}) {
  var remaining = gap.orZeroIfNegative;
  var ordinary = Money.zero;
  var gains = Money.zero;
  var bufferDepleted = false;
  var breached = false;
  var headroom = magiHeadroom;
  final penalties = <Id, ({Money early, Money hsa})>{};

  void penalise(Id taxUnitId, {Money? early, Money? hsa}) {
    final current = penalties[taxUnitId] ?? (early: Money.zero, hsa: Money.zero);
    penalties[taxUnitId] = (
      early: current.early + (early ?? Money.zero),
      hsa: current.hsa + (hsa ?? Money.zero),
    );
  }

  Person? owner(AccountState a) => household.personById(a.account.personId);
  Id unitOf(AccountState a) => owner(a)?.taxUnitId ?? household.taxUnits.first.id;

  for (final source in assumptions.withdrawalOrder) {
    if (!remaining.isPositive) break;

    for (final state in accounts.values) {
      if (!remaining.isPositive) break;
      if (!_matches(source, state)) continue;

      final person = owner(state);
      if (person == null) continue;
      final age = person.ageIn(year);
      final penaltyFree = person.isPenaltyFreeIn(year);

      // §4.5: the cash source draws down to the buffer target, and below it
      // only when every other source is exhausted.
      var available = state.balance;
      if (source == WithdrawalSource.cash &&
          state.account.targetBalanceMonths != null) {
        final target =
            annualExpenses * (state.account.targetBalanceMonths! / 12);
        final aboveTarget = (state.balance - target).orZeroIfNegative;
        if (aboveTarget.isPositive) {
          available = aboveTarget;
        } else {
          continue;
        }
      }
      if (source == WithdrawalSource.rothIraBasis) {
        available = minMoney(available, state.rothContributionBasis);
      }
      if (!available.isPositive) continue;

      // The ceiling binds only the MAGI-counting sources; the non-MAGI ones are
      // drawn freely, and the engine spends them first precisely so the
      // counting draws stay small (§8.4.4).
      var take = minMoney(remaining, available);
      if (headroom != null) {
        switch (source) {
          case WithdrawalSource.traditional:
          case WithdrawalSource.rothEarnings:
          case WithdrawalSource.hsaNonMedical:
            take = minMoney(take, headroom);
          case WithdrawalSource.taxable:
            // Bound partially: only the gain fraction counts, so a ceiling with
            // $10,000 of headroom against an account that is 30% gain permits a
            // draw of about $33,000. The fraction is the account's own basis
            // ratio, which falls out of §6.3 without an assumption.
            final gainShare =
                state.gainPortionOf(Money.dollars(1)).ratioTo(Money.dollars(1));
            if (gainShare > 0) {
              take = minMoney(take, headroom / gainShare);
            }
          case WithdrawalSource.cash:
          case WithdrawalSource.rothIraBasis:
          case WithdrawalSource.hsaQualifiedMedical:
            break;
        }
      }
      if (!take.isPositive) continue;

      if (source == WithdrawalSource.taxable) {
        gains += state.gainPortionOf(take);
      }
      final taken = state.withdraw(take,
          fromRothBasis: source == WithdrawalSource.rothIraBasis);
      if (taken.isZero) continue;
      remaining -= taken;

      if (headroom != null) {
        final counting = switch (source) {
          WithdrawalSource.taxable => state.gainPortionOf(taken),
          WithdrawalSource.traditional ||
          WithdrawalSource.rothEarnings ||
          WithdrawalSource.hsaNonMedical =>
            taken,
          _ => Money.zero,
        };
        headroom = (headroom! - counting).orZeroIfNegative;
      }

      switch (source) {
        case WithdrawalSource.traditional:
          ordinary += taken;
          if (!penaltyFree) penalise(unitOf(state), early: taken);
        case WithdrawalSource.rothEarnings:
          // Qualified needs 59½ *and* the account's own five-year clock.
          final qualified = penaltyFree &&
              (state.account.rothFirstContributionYear ?? year) + 5 <= year;
          if (!qualified) {
            ordinary += taken;
            penalise(unitOf(state), early: taken);
          }
        case WithdrawalSource.hsaNonMedical:
          ordinary += taken;
          if (age < 65) penalise(unitOf(state), hsa: taken);
        case WithdrawalSource.cash ||
              WithdrawalSource.rothIraBasis ||
              WithdrawalSource.hsaQualifiedMedical:
          break; // non-MAGI, tax- and penalty-free
        case WithdrawalSource.taxable:
          break; // only the gain portion counts, already recorded
      }
    }
  }

  // Only once the non-MAGI balances are exhausted and the year is still not
  // covered does the engine breach the ceiling, accepting the subsidy loss
  // rather than under-funding the year (§8.4.4).
  if (remaining.isPositive && magiHeadroom != null) {
    breached = true;
    final unbound = sourceGap(
      remaining,
      household: household,
      accounts: accounts,
      assumptions: assumptions,
      taxYear: taxYear,
      year: year,
      annualExpenses: annualExpenses,
    );
    remaining -= unbound.total;
    ordinary += unbound.ordinaryIncome;
    gains += unbound.realizedGains;
    unbound.penalties.forEach((unit, p) {
      penalise(unit,
          early: p.earlyRetirementDraws, hsa: p.hsaNonMedicalDraws);
    });
    if (unbound.bufferDepleted) bufferDepleted = true;
  }

  // Everything else exhausted: breach the buffer rather than fail (§4.5).
  if (remaining.isPositive) {
    for (final state in accounts.values) {
      if (!remaining.isPositive) break;
      if (state.account.kind != AccountKind.cashSavings &&
          state.account.kind != AccountKind.cashChecking) {
        continue;
      }
      final taken = state.withdraw(minMoney(remaining, state.balance));
      if (taken.isPositive) {
        bufferDepleted = true;
        remaining -= taken;
      }
    }
  }

  return Draw(
    total: gap.orZeroIfNegative - remaining,
    ordinaryIncome: ordinary,
    realizedGains: gains,
    penalties: {
      for (final e in penalties.entries)
        e.key: WithdrawalPenalties(
          earlyRetirementDraws: e.value.early,
          hsaNonMedicalDraws: e.value.hsa,
        ),
    },
    shortfall: remaining.isPositive,
    bufferDepleted: bufferDepleted,
    magiCeilingBreached: breached,
  );
}

bool _matches(WithdrawalSource source, AccountState a) {
  final kind = a.account.kind;
  return switch (source) {
    WithdrawalSource.cash => kind == AccountKind.cashSavings ||
        kind == AccountKind.cashChecking,
    // From rothIra accounts only: the contributions-first ordering it relies on
    // is an IRA rule, and a designated Roth account has no such ordering.
    WithdrawalSource.rothIraBasis => kind == AccountKind.rothIra,
    WithdrawalSource.taxable => kind == AccountKind.taxableBrokerage,
    WithdrawalSource.traditional =>
      a.account.taxTreatment == TaxTreatment.taxDeferred,
    WithdrawalSource.hsaQualifiedMedical ||
    WithdrawalSource.hsaNonMedical =>
      kind == AccountKind.hsa,
    WithdrawalSource.rothEarnings =>
      a.account.taxTreatment == TaxTreatment.roth,
  };
}

/// §8.4.2. Required minimum distributions, a **floor on withdrawals** standing
/// outside `withdrawalOrder` entirely.
///
/// Taken at the top of the year, where they land as ordinary income and cash
/// before the pipeline runs. They apply to anyone past their RMD age, working
/// or not.
Map<Id, Money> requiredMinimumDistributions({
  required Household household,
  required Map<Id, AccountState> accounts,
  required TaxYear taxYear,
  required int year,
}) {
  final byTaxUnit = <Id, Money>{};
  for (final person in household.people) {
    final rmdAge = taxYear.rmdAgeFor(person.birthDate.year);
    if (rmdAge == null || person.ageIn(year) < rmdAge) continue;

    final divisor = taxYear.rmdDivisorFor(person.ageIn(year));
    for (final account in household.accountsFor(person.id)) {
      // taxDeferred only. Roth IRAs have never had RMDs and designated Roth
      // accounts no longer do (§8.4.2).
      if (account.taxTreatment != TaxTreatment.taxDeferred) continue;
      final state = accounts[account.id];
      if (state == null || !state.balance.isPositive) continue;

      final rmd = minMoney(state.balance / divisor, state.balance);
      state.withdraw(rmd);
      byTaxUnit[person.taxUnitId] =
          (byTaxUnit[person.taxUnitId] ?? Money.zero) + rmd;
    }
  }
  return byTaxUnit;
}
