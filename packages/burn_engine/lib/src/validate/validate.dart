/// §12's invariants, as far as a household can be checked while sitting still.
///
/// Invariants 20, 21 and 24 are conditions on a projected *year* rather than on
/// stored data, so the loop raises them as flags (§6); 16's "no expense is
/// counted twice" is partly a judgement about what a line means, and rides on
/// `possibleDoubleCount`; 19 is a persistence rule. Everything else is here.
///
/// Invariants 9, 10 and 11 need no check: `Rate` is a decimal by construction,
/// `Money` is integer cents by construction, and `birthDate` is a `DateTime`.
library;

import '../entities/assumptions.dart';
import '../entities/household.dart';
import '../enums.dart';
import '../types.dart';
import 'finding.dart';

List<Finding> validateHousehold(
  Household h, {
  /// The classes that exist, where the caller knows them. Omitted, the
  /// allocation check is skipped rather than guessed at.
  Set<Id>? assetClassIds,
}) {
  final findings = <Finding>[];
  void report(int n, Severity s, String m, [String? id]) =>
      findings.add(Finding(n, s, m, entityId: id));

  final personIds = {for (final p in h.people) p.id};
  final taxUnitIds = {for (final t in h.taxUnits) t.id};
  final accountIds = {for (final a in h.accounts) a.id};
  final categoryIds = {for (final c in h.expenseCategories) c.id};
  final employerIds = {for (final e in h.employers) e.id};
  final assetIds = {for (final a in h.assets) a.id};
  final liabilityIds = {for (final l in h.liabilities) l.id};

  // 1. Every ExpenseItem belongs to exactly one ExpenseCategory, which is how
  //    it reaches a Household.
  for (final item in h.expenseItems) {
    if (!categoryIds.contains(item.categoryId)) {
      report(1, Severity.blocking,
          'expense "${item.label}" names no existing category', item.id);
    }
  }

  // 2. Every IncomeStream, Account and PayrollDeduction belongs to exactly one
  //    Person.
  for (final s in h.incomeStreams) {
    if (!personIds.contains(s.personId)) {
      report(2, Severity.blocking, 'income "${s.label}" has no owner', s.id);
    }
  }
  for (final a in h.accounts) {
    if (!personIds.contains(a.personId)) {
      report(2, Severity.blocking, 'account "${a.label}" has no owner', a.id);
    }
  }
  for (final d in h.payrollDeductions) {
    if (!personIds.contains(d.personId)) {
      report(2, Severity.blocking, 'deduction "${d.label}" has no owner', d.id);
    }
  }

  // 3. Every Person belongs to exactly one TaxUnit.
  for (final p in h.people) {
    if (!taxUnitIds.contains(p.taxUnitId)) {
      report(3, Severity.blocking,
          '${p.displayName} names no existing tax unit', p.id);
    }
  }

  // 4. Every household-owned entity names this Household.
  void ownedByHousehold(int n, String kind, String id, String householdId) {
    if (householdId != h.id) {
      report(n, Severity.blocking, '$kind belongs to another household', id);
    }
  }
  for (final t in h.taxUnits) {
    ownedByHousehold(4, 'tax unit', t.id, t.householdId);
  }
  for (final a in h.assets) {
    ownedByHousehold(4, 'asset "${a.label}"', a.id, a.householdId);
  }
  for (final l in h.liabilities) {
    ownedByHousehold(4, 'debt "${l.label}"', l.id, l.householdId);
  }
  for (final c in h.expenseCategories) {
    ownedByHousehold(4, 'category "${c.label}"', c.id, c.householdId);
  }
  for (final e in h.oneTimeEvents) {
    ownedByHousehold(4, 'event "${e.label}"', e.id, e.householdId);
  }

  // 5. Asset.securedByLiabilityId and Liability.securedAssetId must agree.
  for (final a in h.assets) {
    final lid = a.securedByLiabilityId;
    if (lid == null) continue;
    if (!liabilityIds.contains(lid)) {
      report(5, Severity.blocking,
          '"${a.label}" is secured by a debt that does not exist', a.id);
      continue;
    }
    final debt = h.liabilities.firstWhere((l) => l.id == lid);
    if (debt.securedAssetId != a.id) {
      report(5, Severity.warning,
          '"${a.label}" and "${debt.label}" disagree about securing each other',
          a.id);
    }
  }
  for (final l in h.liabilities) {
    final aid = l.securedAssetId;
    if (aid != null && !assetIds.contains(aid)) {
      report(5, Severity.blocking,
          '"${l.label}" secures an asset that does not exist', l.id);
    }
  }

  // 7. allocationWeights sums to 1.0 under weighted allocation.
  for (final a in h.accounts) {
    if (a.allocationMode != AllocationMode.weighted) continue;
    final total =
        a.allocationWeights.fold<double>(0, (sum, w) => sum + w.weight);
    if ((total - 1.0).abs() > 1e-6) {
      report(7, Severity.blocking,
          '"${a.label}" allocation weights sum to $total, not 1.0', a.id);
    }
  }

  // 8. A percentOfGross contribution names base streams, all belonging to the
  //    account's own person.
  for (final a in h.accounts) {
    final c = a.contribution;
    if (c.mode != ContributionMode.percentOfGross) continue;
    // A share of nothing is nothing. An account nobody is paying into needs
    // no salary behind it, and blocking on one turns a dormant plan into an
    // error the user cannot act on.
    if (c.value <= 0) continue;
    if (c.contributionBaseStreamIds.isEmpty) {
      report(8, Severity.blocking,
          '"${a.label}" is a percentage of nothing: no base stream named', a.id);
      continue;
    }
    for (final sid in c.contributionBaseStreamIds) {
      final stream =
          h.incomeStreams.where((s) => s.id == sid).firstOrNull;
      if (stream == null) {
        report(8, Severity.blocking,
            '"${a.label}" names an income stream that does not exist', a.id);
      } else if (stream.personId != a.personId) {
        report(8, Severity.blocking,
            '"${a.label}" is funded from another person\'s income', a.id);
      }
    }
  }

  // 12. Every Money field is non-negative, OneTimeEvent.amount excepted.
  void nonNegative(String what, Money m, String id) {
    if (m.isNegative) {
      report(12, Severity.blocking, '$what is negative', id);
    }
  }
  for (final a in h.accounts) {
    nonNegative('"${a.label}" balance', a.balance, a.id);
    nonNegative('"${a.label}" cost basis', a.costBasis, a.id);
    nonNegative(
        '"${a.label}" Roth basis', a.rothContributionBasis, a.id);
    if (a.contribution.mode == ContributionMode.fixedAmount &&
        a.contribution.value < 0) {
      report(12, Severity.blocking,
          '"${a.label}" contributes a negative amount, which would act as an '
          'untaxed withdrawal',
          a.id);
    }
  }
  for (final s in h.incomeStreams) {
    nonNegative('"${s.label}" pay', s.grossAnnualAmount, s.id);
  }
  for (final i in h.expenseItems) {
    nonNegative('"${i.label}" amount', i.amount, i.id);
  }
  for (final l in h.liabilities) {
    nonNegative('"${l.label}" balance', l.currentBalance, l.id);
    nonNegative('"${l.label}" payment', l.monthlyPayment, l.id);
  }

  // 12a. An account names an asset class that is there. A missing one blends
  //      to a zero return, so the account simply stops growing and nothing
  //      says why: the quietest way a projection can be wrong.
  for (final a in h.accounts) {
    for (final id in [
      if (a.allocationMode == AllocationMode.singleClass) a.assetAllocationId,
      a.retirementAllocationId,
      if (a.allocationMode == AllocationMode.weighted)
        for (final w in a.allocationWeights) w.assetClassId,
    ]) {
      if (id == null ||
          assetClassIds == null ||
          assetClassIds.contains(id)) {
        continue;
      }
      report(12, Severity.blocking,
          '"${a.label}" is invested in something that is not there', a.id);
    }
  }

  // 12b. A housing cost names a home that exists: a primaryResidence Asset or
  //      the rent it belongs to.
  final expenseCategories = {for (final c in h.expenseCategories) c.id: c};
  for (final item in h.expenseItems) {
    final home = item.housingId;
    if (home == null) continue;
    final isResidence = h.assets.any((a) =>
        a.id == home && a.category == AssetCategory.primaryResidence);
    final isRent = h.expenseItems.any((i) =>
        i.id == home &&
        (expenseCategories[i.categoryId]?.metaCategory) ==
            MetaCategory.housing);
    if (!isResidence && !isRent) {
      report(12, Severity.blocking,
          '"${item.label}" is attached to a home that is not there', item.id);
    }
  }

  // 12c. Education spending and a 529 name a child who is in the plan.
  final childIds = {for (final d in h.dependents) d.id};
  for (final item in h.expenseItems) {
    if (item.dependentId != null && !childIds.contains(item.dependentId)) {
      report(12, Severity.blocking,
          '"${item.label}" is for a child who is not in the plan', item.id);
    }
  }
  for (final a in h.accounts) {
    if (a.beneficiaryId != null && !childIds.contains(a.beneficiaryId)) {
      report(12, Severity.blocking,
          '"${a.label}" is saving for a child who is not in the plan', a.id);
    }
  }

  // 13. rothContributionBasis <= balance for Roth accounts.
  for (final a in h.accounts) {
    if (a.taxTreatment == TaxTreatment.roth &&
        a.rothContributionBasis > a.balance) {
      report(13, Severity.blocking,
          '"${a.label}" Roth basis is above its balance', a.id);
    }
  }

  // 14. escrow <= payment, and PMI <= escrow, where each is set.
  for (final l in h.liabilities) {
    final escrow = l.monthlyEscrowAmount;
    final pmi = l.monthlyPmiAmount;
    if (escrow != null && escrow > l.monthlyPayment) {
      report(14, Severity.blocking,
          '"${l.label}" escrow exceeds its whole payment', l.id);
    }
    if (pmi != null && escrow != null && pmi > escrow) {
      report(14, Severity.blocking,
          '"${l.label}" PMI exceeds its escrow, of which it is a part', l.id);
    }
  }

  // 16. A negative OneTimeEvent must name the account it comes out of.
  for (final e in h.oneTimeEvents) {
    if (e.isOutflow && e.accountId == null) {
      report(16, Severity.blocking,
          '"${e.label}" spends money from nowhere: name the account', e.id);
    }
    if (e.accountId != null && !accountIds.contains(e.accountId)) {
      report(25, Severity.blocking,
          '"${e.label}" names an account outside this household', e.id);
    }
  }

  // 17. An Asset with a planned sale must say where the proceeds land.
  for (final a in h.assets) {
    if (a.plannedSaleYear == null) continue;
    if (a.saleProceedsAccountId == null) {
      report(17, Severity.blocking,
          '"${a.label}" is sold with nowhere for the proceeds to go', a.id);
    } else if (!accountIds.contains(a.saleProceedsAccountId)) {
      report(25, Severity.blocking,
          '"${a.label}" sends proceeds outside this household', a.id);
    }
  }

  // 21. Depreciation cannot exceed the depreciable basis, and is zero outside
  //     investment property.
  for (final a in h.assets) {
    if (a.category == AssetCategory.investmentProperty) {
      final depreciable = a.costBasis * (1 - a.landFraction);
      if (a.accumulatedDepreciation > depreciable) {
        report(21, Severity.blocking,
            '"${a.label}" has depreciated past its depreciable basis', a.id);
      }
    } else if (!a.accumulatedDepreciation.isZero) {
      report(21, Severity.warning,
          '"${a.label}" carries depreciation but is not a rental', a.id);
    }
  }

  // 22. A dependent's support cannot end before they are born.
  for (final t in h.taxUnits) {
    for (final d in t.dependents) {
      if (d.resolvedSupportEndYear < d.birthDate.year) {
        report(22, Severity.blocking,
            'a dependent stops being supported before they are born', t.id);
      }
    }
  }

  // 24. Attribution is required once a household holds more than one TaxUnit,
  //     since §4.3's sums are per TaxUnit and an unattributed one reaches both.
  if (h.taxUnits.length > 1) {
    void needsPerson(String kind, String label, Id? personId, String id) {
      if (personId == null) {
        report(24, Severity.blocking,
            '$kind "$label" is unattributed, and this household files two '
            'returns',
            id);
      } else if (!personIds.contains(personId)) {
        report(24, Severity.blocking,
            '$kind "$label" names someone outside this household', id);
      }
    }
    for (final a in h.assets) {
      needsPerson('asset', a.label, a.personId, a.id);
    }
    for (final l in h.liabilities) {
      needsPerson('debt', l.label, l.personId, l.id);
    }
    for (final e in h.oneTimeEvents) {
      needsPerson('event', e.label, e.personId, e.id);
    }
  }

  // 25. A named Employer belongs to this household.
  for (final s in h.incomeStreams) {
    if (s.employerId != null && !employerIds.contains(s.employerId)) {
      report(25, Severity.blocking,
          '"${s.label}" names an employer outside this household', s.id);
    }
  }
  for (final a in h.accounts) {
    if (a.employerId != null && !employerIds.contains(a.employerId)) {
      report(25, Severity.blocking,
          '"${a.label}" names an employer outside this household', a.id);
    }
  }
  for (final e in h.employers) {
    ownedByHousehold(26, 'employer "${e.label}"', e.id, e.householdId);
  }
  for (final d in h.payrollDeductions) {
    if (d.expenseCategoryId != null &&
        !categoryIds.contains(d.expenseCategoryId)) {
      report(25, Severity.blocking,
          '"${d.label}" names a category outside this household', d.id);
    }
  }

  // 26. Claiming age is in [62, 70].
  for (final p in h.people) {
    final ss = p.socialSecurity;
    if (ss == null) continue;
    if (ss.claimingAge < 62 || ss.claimingAge > 70) {
      report(26, Severity.blocking,
          '${p.displayName} claims Social Security at ${ss.claimingAge}, '
          'outside 62 to 70',
          p.id);
    }
  }

  // 28. A roth or taxDeferred account has a limit family other than none.
  for (final a in h.accounts) {
    final treated = a.taxTreatment == TaxTreatment.roth ||
        a.taxTreatment == TaxTreatment.taxDeferred;
    if (treated && a.limitFamily == LimitFamily.none) {
      report(28, Severity.blocking,
          '"${a.label}" is tax-advantaged and uncapped, so it could take '
          'unlimited contributions',
          a.id);
    }
  }

  return findings;
}

/// §12's assumption-level invariants, 27 and 29.
List<Finding> validateAssumptions(Assumptions a) {
  final findings = <Finding>[];
  if (a.safeWithdrawalRate <= 0) {
    findings.add(const Finding(27, Severity.blocking,
        'the safe withdrawal rate must be above zero: §8.1 divides by it'));
  }
  if (!a.contributionWaterfall.contains(WaterfallStep.taxableBrokerage)) {
    findings.add(const Finding(
        29,
        Severity.blocking,
        'the waterfall has no taxableBrokerage step, so a surplus would have '
        'nowhere to land'));
  }
  return findings;
}

/// Whether anything found stops the engine running.
extension FindingList on List<Finding> {
  bool get hasBlocking => any((f) => f.severity == Severity.blocking);
  Iterable<Finding> get blocking =>
      where((f) => f.severity == Severity.blocking);
  Iterable<Finding> get warnings =>
      where((f) => f.severity == Severity.warning);
}
