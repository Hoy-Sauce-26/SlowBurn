/// §3.4. What a person is allowed to put in, and what the employer adds.
///
/// Every cap here is **per person**: the elective deferral limit is one limit
/// across every account sharing it, so someone who changed jobs mid-year and
/// holds two 401(k)s gets one limit between them, not two.
library;

import '../entities/account.dart';
import '../entities/household.dart';
import '../entities/person.dart';
import '../enums.dart';
import '../taxyear/tax_year.dart';
import '../types.dart';
import 'income_tax.dart';

/// One account's resolved contribution and the employer money it attracts.
class ResolvedContribution {
  final Id accountId;

  /// What the user asked for, before any cap.
  final Money uncapped;

  /// After the family limit, the §415(c) ceiling, and the pro-rata split.
  final Money employee;

  /// Employer dollars, credited separately and never surplus to allocate.
  final Money employerMatch;

  /// Raised where a cap actually bit (invariant 19).
  final bool limitExceeded;

  const ResolvedContribution({
    required this.accountId,
    required this.uncapped,
    required this.employee,
    required this.employerMatch,
    required this.limitExceeded,
  });
}

/// The family limit for [family] and this person's age, including catch-up.
Money familyCap(
  LimitFamily family, {
  required TaxYear taxYear,
  required int age,
  required HsaTier hsaTier,
}) {
  final limit = taxYear.contributionLimits[family];
  if (limit == null) return Money.zero;
  final catchUp = limit.catchUpFor(age);
  return switch (family) {
    LimitFamily.hsa => switch (hsaTier) {
        HsaTier.none => Money.zero,
        HsaTier.self => (limit.selfOnly ?? Money.zero) + catchUp,
        HsaTier.family => (limit.family ?? Money.zero) + catchUp,
      },
    // No federal annual limit; the gift-tax exclusion is not modeled.
    LimitFamily.education || LimitFamily.none => _unbounded,
    _ => (limit.annual ?? Money.zero) + catchUp,
  };
}

/// Stands in for "no cap". Large enough that nothing reaches it and finite so
/// arithmetic on it stays defined.
const _unbounded = Money(1 << 52);

bool isUnbounded(Money cap) => cap.cents >= _unbounded.cents;

/// §3.4, for one person in one year.
///
/// [requested] overrides what an account's committed contribution asks for,
/// which is how the waterfall proposes an addition and asks what survives.
List<ResolvedContribution> resolveContributions(
  Person person, {
  required Household household,
  required TaxYear taxYear,
  required int year,
  required int currentYear,
  Map<Id, Money> requested = const {},
}) {
  final accounts = household.accountsFor(person.id).toList();
  final age = person.ageIn(year);
  final hsaTier = person.hsaTierIn(year);

  final uncapped = {
    for (final a in accounts)
      a.id: requested[a.id] ??
          resolveCommittedContribution(a, household, year, currentYear),
  };

  // The family limit is shared across every account carrying it. Where the
  // total asks for more than the limit allows, each account is reduced pro
  // rata by its share (§3.4).
  final byFamily = <LimitFamily, List<Account>>{};
  for (final a in accounts) {
    byFamily.putIfAbsent(a.limitFamily, () => []).add(a);
  }

  final capped = <Id, Money>{};
  final exceeded = <Id>{};
  for (final entry in byFamily.entries) {
    final cap =
        familyCap(entry.key, taxYear: taxYear, age: age, hsaTier: hsaTier);
    final asked = sumMoney(entry.value.map((a) => uncapped[a.id]!));
    if (isUnbounded(cap) || asked <= cap) {
      for (final a in entry.value) {
        capped[a.id] = uncapped[a.id]!;
      }
      continue;
    }
    for (final a in entry.value) {
      final share = uncapped[a.id]!.ratioTo(asked);
      capped[a.id] = cap * share;
      if (uncapped[a.id]!.isPositive) exceeded.add(a.id);
    }
  }

  // §415(c) bounds employee plus employer dollars against the pay behind that
  // employer, so two unrelated employers give two ceilings (§3.4).
  final results = <ResolvedContribution>[];
  for (final a in accounts) {
    final employee0 = capped[a.id] ?? Money.zero;
    final comp = employerCompFor(a,
        household: household,
        person: person,
        taxYear: taxYear,
        year: year,
        currentYear: currentYear);
    final match = a.contribution.employerMatch?.matchOn(employee0, comp) ??
        Money.zero;

    var employee = employee0;
    var hit = exceeded.contains(a.id);
    if (a.employerId != null) {
      final catchUp =
          taxYear.contributionLimits[a.limitFamily]?.catchUpFor(age) ??
              Money.zero;
      final room415c =
          (minMoney(taxYear.annualAdditions415c, comp) + catchUp - match)
              .orZeroIfNegative;
      if (employee > room415c) {
        employee = room415c;
        hit = true;
      }
    }

    results.add(ResolvedContribution(
      accountId: a.id,
      uncapped: uncapped[a.id]!,
      employee: employee,
      employerMatch: match,
      limitExceeded: hit,
    ));
  }
  return results;
}

/// The pay behind this account's employer, bounded by §401(a)(17) (§3.4).
///
/// Zero where no employer sponsors the account, which is the right answer: a
/// match needs pay behind it, and an IRA has no employer at all.
Money employerCompFor(
  Account account, {
  required Household household,
  required Person person,
  required TaxYear taxYear,
  required int year,
  required int currentYear,
}) {
  if (account.employerId == null) return Money.zero;
  final pay = sumMoney(household
      .streamsFor(person.id)
      .where((s) => s.employerId == account.employerId)
      .map((s) => s.resolvedAmount(year, currentYear: currentYear)));
  return minMoney(pay, taxYear.compensationLimit401a17);
}
