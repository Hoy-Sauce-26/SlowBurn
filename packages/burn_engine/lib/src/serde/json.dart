/// §11. The single versioned JSON file a household exports to.
///
/// Pure Dart, so a round trip is testable as arithmetic rather than through a
/// widget harness. Money crosses as **integer cents** (invariant 10), which is
/// what makes the round trip exact rather than nearly exact.
library;

import 'dart:convert';

import '../entities/account.dart';
import '../entities/assumptions.dart';
import '../entities/events.dart';
import '../entities/expenses.dart';
import '../entities/household.dart';
import '../entities/income.dart';
import '../entities/payroll.dart';
import '../entities/person.dart';
import '../entities/property.dart';
import '../enums.dart';
import '../types.dart';

/// Bumped whenever a shape changes; import migrates forward from it (§11).
const exportSchemaVersion = 1;

class ExportFormatException implements Exception {
  final String message;
  const ExportFormatException(this.message);
  @override
  String toString() => 'ExportFormatException: $message';
}

/// A whole household plus the scenarios that belong to it (§11).
///
/// `AssetClass` rates travel too: the user edits them and no bundle can restore
/// an edited rate. `TaxYear` never does, being the only thing that ships in.
class ExportBundle {
  final Household household;
  final List<Scenario> scenarios;
  final List<AssetClass> assetClasses;

  const ExportBundle({
    required this.household,
    required this.scenarios,
    required this.assetClasses,
  });
}

String exportToJson(ExportBundle bundle) => const JsonEncoder.withIndent('  ')
    .convert(exportToMap(bundle));

Map<String, dynamic> exportToMap(ExportBundle bundle) => {
      'schemaVersion': exportSchemaVersion,
      'household': _household(bundle.household),
      'scenarios': bundle.scenarios.map(_scenario).toList(),
      'assetClasses': bundle.assetClasses.map(_assetClass).toList(),
    };

ExportBundle importFromJson(String source) =>
    importFromMap(jsonDecode(source) as Map<String, dynamic>);

ExportBundle importFromMap(Map<String, dynamic> j) {
  final version = j['schemaVersion'];
  if (version is! int) {
    throw const ExportFormatException('no schemaVersion: not a Slow Burn file');
  }
  if (version > exportSchemaVersion) {
    throw ExportFormatException(
      'schema version $version was written by a newer build; '
      'this one understands $exportSchemaVersion',
    );
  }
  // A malformed file should say what is wrong with it, not surface a cast
  // error from three layers down. Import is a user-facing path: the file may
  // have been hand-edited, truncated, or written by something else entirely.
  try {
    return ExportBundle(
      household: _readHousehold(j['household'] as Map<String, dynamic>),
      scenarios: _list(j['scenarios']).map(_readScenario).toList(),
      assetClasses: _list(j['assetClasses']).map(_readAssetClass).toList(),
    );
  } on ExportFormatException {
    rethrow;
  } catch (e) {
    throw ExportFormatException('could not read this file: $e');
  }
}

// --- writing -----------------------------------------------------------------

int _c(Money m) => m.cents;
int? _cn(Money? m) => m?.cents;

Map<String, dynamic> _household(Household h) => {
      'id': h.id,
      'expenseSharing': h.expenseSharing.name,
      'taxUnits': h.taxUnits.map(_taxUnit).toList(),
      'people': h.people.map(_person).toList(),
      'employers': h.employers
          .map((e) => {'id': e.id, 'householdId': e.householdId, 'label': e.label})
          .toList(),
      'incomeStreams': h.incomeStreams.map(_stream).toList(),
      'accounts': h.accounts.map(_account).toList(),
      'payrollDeductions': h.payrollDeductions.map(_deduction).toList(),
      'assets': h.assets.map(_asset).toList(),
      'liabilities': h.liabilities.map(_liability).toList(),
      'expenseCategories': h.expenseCategories.map(_category).toList(),
      'expenseItems': h.expenseItems.map(_item).toList(),
      'oneTimeEvents': h.oneTimeEvents.map(_event).toList(),
    };

Map<String, dynamic> _taxUnit(TaxUnit t) => {
      'id': t.id,
      'householdId': t.householdId,
      'filingStatus': t.filingStatus.name,
      'stateCode': t.stateCode,
      'localityCode': t.localityCode,
      'dependents': t.dependents
          .map((d) => {
                'birthDate': d.birthDate.toIso8601String(),
                'isStudent': d.isStudent,
                'supportEndYear': d.supportEndYear,
              })
          .toList(),
      'benchmarkPremiumOverride': _cn(t.benchmarkPremiumOverride),
      'itemizedDeductionTotal': _cn(t.itemizedDeductionTotal),
    };

Map<String, dynamic> _person(Person p) => {
      'id': p.id,
      'displayName': p.displayName,
      'birthDate': p.birthDate.toIso8601String(),
      'taxUnitId': p.taxUnitId,
      'plannedRetirementAge': p.plannedRetirementAge,
      'hsaCoverage': p.hsaCoverage
          .map((e) => {'fromYear': e.fromYear, 'tier': e.tier.name})
          .toList(),
      'employerHealthCoverageEndYear': p.employerHealthCoverageEndYear,
      'socialSecurity': p.socialSecurity == null
          ? null
          : {
              'personId': p.socialSecurity!.personId,
              'estimatedMonthlyBenefitAtFra':
                  _c(p.socialSecurity!.estimatedMonthlyBenefitAtFra),
              'claimingAge': p.socialSecurity!.claimingAge,
              'includeInProjection': p.socialSecurity!.includeInProjection,
            },
    };

Map<String, dynamic> _stream(IncomeStream s) => {
      'id': s.id,
      'personId': s.personId,
      'employerId': s.employerId,
      'label': s.label,
      'kind': s.kind.name,
      'grossAnnualAmount': _c(s.grossAnnualAmount),
      'realGrowthRate': s.realGrowthRate,
      'startYear': s.startYear,
      'endYear': s.endYear,
      'startMonth': s.startMonth,
      'endMonth': s.endMonth,
      'isFicaSubject': s.isFicaSubject,
      'isQualifiedBusinessIncome': s.isQualifiedBusinessIncome,
      'isSpecifiedServiceBusiness': s.isSpecifiedServiceBusiness,
      'variability': s.variability.name,
    };

Map<String, dynamic> _account(Account a) => {
      'id': a.id,
      'personId': a.personId,
      'label': a.label,
      'kind': a.kind.wireName,
      'taxTreatment': a.taxTreatment.name,
      'limitFamily': a.limitFamily.name,
      'balance': _c(a.balance),
      'costBasis': _c(a.costBasis),
      'rothContributionBasis': _c(a.rothContributionBasis),
      'rothFirstContributionYear': a.rothFirstContributionYear,
      'contribution': _contribution(a.contribution),
      'employerId': a.employerId,
      'allocationMode': a.allocationMode.name,
      'assetAllocationId': a.assetAllocationId,
      'retirementAllocationId': a.retirementAllocationId,
      'allocationWeights': a.allocationWeights
          .map((w) => {'assetClassId': w.assetClassId, 'weight': w.weight})
          .toList(),
      'isRestrictedPurpose': a.isRestrictedPurpose,
      'targetBalanceMonths': a.targetBalanceMonths,
    };

Map<String, dynamic> _contribution(Contribution c) => {
      'mode': c.mode.name,
      'value': c.value,
      'contributionBaseStreamIds': c.contributionBaseStreamIds,
      'employerMatch': c.employerMatch == null
          ? null
          : {
              'formula': c.employerMatch!.formula.name,
              'matchRate': c.employerMatch!.matchRate,
              'matchLimitPercentOfSalary':
                  c.employerMatch!.matchLimitPercentOfSalary,
              'tiers': c.employerMatch!.tiers
                  .map((t) => {
                        'upToPercentOfSalary': t.upToPercentOfSalary,
                        'matchRate': t.matchRate,
                      })
                  .toList(),
              'vestingSchedule': _vesting(c.employerMatch!.vestingSchedule),
            },
      'reducesFederalTaxableIncome': c.reducesFederalTaxableIncome,
      'reducesStateTaxableIncome': c.reducesStateTaxableIncome,
      'reducesFicaWages': c.reducesFicaWages,
      'startYear': c.startYear,
      'endYear': c.endYear,
      'startMonth': c.startMonth,
      'endMonth': c.endMonth,
    };

Map<String, dynamic>? _vesting(VestingSchedule? v) => switch (v) {
      null => null,
      ImmediateVesting() => {'kind': 'immediate'},
      CliffVesting(:final years) => {'kind': 'cliff', 'years': years},
      GradedVesting(:final schedule) => {
          'kind': 'graded',
          'schedule': schedule
              .map((e) => {'years': e.years, 'vested': e.vested})
              .toList(),
        },
    };

Map<String, dynamic> _deduction(PayrollDeduction d) => {
      'id': d.id,
      'personId': d.personId,
      'label': d.label,
      'kind': d.kind.name,
      'annualAmount': _c(d.annualAmount),
      'reducesFederalTaxableIncome': d.reducesFederalTaxableIncome,
      'reducesStateTaxableIncome': d.reducesStateTaxableIncome,
      'reducesFicaWages': d.reducesFicaWages,
      'expenseCategoryId': d.expenseCategoryId,
      'startYear': d.startYear,
      'endYear': d.endYear,
      'startMonth': d.startMonth,
      'endMonth': d.endMonth,
    };

Map<String, dynamic> _asset(Asset a) => {
      'id': a.id,
      'householdId': a.householdId,
      'personId': a.personId,
      'label': a.label,
      'category': a.category.name,
      'currentValue': _c(a.currentValue),
      'costBasis': _c(a.costBasis),
      'realAppreciationRate': a.realAppreciationRate,
      'accumulatedDepreciation': _c(a.accumulatedDepreciation),
      'landFraction': a.landFraction,
      'securedByLiabilityId': a.securedByLiabilityId,
      'acquisitionYear': a.acquisitionYear,
      'purchaseFundingAccountId': a.purchaseFundingAccountId,
      'plannedSaleYear': a.plannedSaleYear,
      'saleProceedsAccountId': a.saleProceedsAccountId,
    };

Map<String, dynamic> _liability(Liability l) => {
      'id': l.id,
      'householdId': l.householdId,
      'personId': l.personId,
      'label': l.label,
      'kind': l.kind.name,
      'currentBalance': _c(l.currentBalance),
      'interestRate': l.interestRate,
      'monthlyPayment': _c(l.monthlyPayment),
      'monthlyEscrowAmount': _cn(l.monthlyEscrowAmount),
      'monthlyPmiAmount': _cn(l.monthlyPmiAmount),
      'escrowContinuesAfterPayoff': l.escrowContinuesAfterPayoff,
      'extraPrincipalPayment': _c(l.extraPrincipalPayment),
      'originationDate': l.originationDate.toIso8601String(),
      'termMonths': l.termMonths,
      'securedAssetId': l.securedAssetId,
      'isTaxDeductibleInterest': l.isTaxDeductibleInterest,
    };

Map<String, dynamic> _category(ExpenseCategory c) => {
      'id': c.id,
      'householdId': c.householdId,
      'label': c.label,
      'metaCategory': c.metaCategory.name,
      'defaultRelativeInflation': c.defaultRelativeInflation,
    };

Map<String, dynamic> _item(ExpenseItem i) => {
      'id': i.id,
      'categoryId': i.categoryId,
      'label': i.label,
      'amount': _c(i.amount),
      'frequency': i.frequency.name,
      'startYear': i.startYear,
      'endYear': i.endYear,
      'startMonth': i.startMonth,
      'endMonth': i.endMonth,
      'relativeInflationRate': i.relativeInflationRate,
      'phase': i.phase.name,
      'postRetirementAmount': _cn(i.postRetirementAmount),
      'housingId': i.housingId,
    };

Map<String, dynamic> _event(OneTimeEvent e) => {
      'id': e.id,
      'householdId': e.householdId,
      'personId': e.personId,
      'label': e.label,
      'year': e.year,
      'amount': _c(e.amount),
      'kind': e.kind.name,
      'accountId': e.accountId,
      'taxTreatment': e.taxTreatment.name,
    };

Map<String, dynamic> _scenario(Scenario s) => {
      'id': s.id,
      'householdId': s.householdId,
      'label': s.label,
      'assumptions': _assumptions(s.assumptions),
    };

Map<String, dynamic> _assumptions(Assumptions a) => {
      'generalInflationRate': a.generalInflationRate,
      'safeWithdrawalRate': a.safeWithdrawalRate,
      'contributionWaterfall':
          a.contributionWaterfall.map((s) => s.name).toList(),
      'withdrawalOrder': a.withdrawalOrder.map((s) => s.name).toList(),
      'highInterestDebtThresholdRate': a.highInterestDebtThresholdRate,
      'includeSocialSecurity': a.includeSocialSecurity,
      'capitalGainsRealizationRate': a.capitalGainsRealizationRate,
      'projectionHorizonAge': a.projectionHorizonAge,
      'acaMagiCeilingPercentOfFpl': a.acaMagiCeilingPercentOfFpl,
      'pmiTerminationLtv': a.pmiTerminationLtv,
      'assetSaleCostRate': a.assetSaleCostRate,
      'assetAppreciationByCategory': {
        for (final e in a.assetAppreciationByCategory.entries)
          e.key.name: e.value,
      },
      'taxYearId': a.taxYearId,
    };

Map<String, dynamic> _assetClass(AssetClass c) => {
      'id': c.id,
      'label': c.label.name,
      'expectedRealReturn': c.expectedRealReturn,
      'pessimisticRealReturn': c.pessimisticRealReturn,
      'optimisticRealReturn': c.optimisticRealReturn,
      'incomeYield': c.incomeYield,
      'qualifiedIncomeFraction': c.qualifiedIncomeFraction,
    };

// --- reading -----------------------------------------------------------------

List<Map<String, dynamic>> _list(dynamic v) =>
    ((v as List<dynamic>?) ?? const [])
        .cast<Map<String, dynamic>>()
        .toList();

Money _m(dynamic v) {
  if (v is int) return Money(v);
  throw ExportFormatException('money must be integer cents, got $v');
}

Money? _mn(dynamic v) => v == null ? null : _m(v);
double _d(dynamic v) => (v as num).toDouble();
DateTime _date(dynamic v) => DateTime.parse(v as String);

T _enum<T extends Enum>(List<T> values, dynamic v, {String? wire}) {
  final name = v as String;
  for (final e in values) {
    if (e.name == name) return e;
  }
  if (wire != null) {
    for (final e in values) {
      if (e.name == wire) return e;
    }
  }
  throw ExportFormatException('"$name" is not one of ${values.map((e) => e.name)}');
}

Household _readHousehold(Map<String, dynamic> j) => Household(
      id: j['id'] as String,
      expenseSharing: _enum(ExpenseSharing.values, j['expenseSharing']),
      taxUnits: _list(j['taxUnits']).map(_readTaxUnit).toList(),
      people: _list(j['people']).map(_readPerson).toList(),
      employers: _list(j['employers'])
          .map((e) => Employer(
                id: e['id'] as String,
                householdId: e['householdId'] as String,
                label: e['label'] as String,
              ))
          .toList(),
      incomeStreams: _list(j['incomeStreams']).map(_readStream).toList(),
      accounts: _list(j['accounts']).map(_readAccount).toList(),
      payrollDeductions:
          _list(j['payrollDeductions']).map(_readDeduction).toList(),
      assets: _list(j['assets']).map(_readAsset).toList(),
      liabilities: _list(j['liabilities']).map(_readLiability).toList(),
      expenseCategories:
          _list(j['expenseCategories']).map(_readCategory).toList(),
      expenseItems: _list(j['expenseItems']).map(_readItem).toList(),
      oneTimeEvents: _list(j['oneTimeEvents']).map(_readEvent).toList(),
    );

TaxUnit _readTaxUnit(Map<String, dynamic> j) => TaxUnit(
      id: j['id'] as String,
      householdId: j['householdId'] as String,
      filingStatus: _enum(FilingStatus.values, j['filingStatus']),
      stateCode: j['stateCode'] as String,
      localityCode: j['localityCode'] as String?,
      dependents: _list(j['dependents'])
          .map((d) => Dependent(
                birthDate: _date(d['birthDate']),
                isStudent: d['isStudent'] as bool? ?? false,
                supportEndYear: d['supportEndYear'] as int?,
              ))
          .toList(),
      benchmarkPremiumOverride: _mn(j['benchmarkPremiumOverride']),
      itemizedDeductionTotal: _mn(j['itemizedDeductionTotal']),
    );

Person _readPerson(Map<String, dynamic> j) {
  final ss = j['socialSecurity'] as Map<String, dynamic>?;
  return Person(
    id: j['id'] as String,
    displayName: j['displayName'] as String,
    birthDate: _date(j['birthDate']),
    taxUnitId: j['taxUnitId'] as String,
    plannedRetirementAge: j['plannedRetirementAge'] as int?,
    hsaCoverage: _list(j['hsaCoverage'])
        .map((e) => HsaCoverageEntry(
              fromYear: e['fromYear'] as int,
              tier: _enum(HsaTier.values, e['tier']),
            ))
        .toList(),
    employerHealthCoverageEndYear: j['employerHealthCoverageEndYear'] as int?,
    socialSecurity: ss == null
        ? null
        : SocialSecurityBenefit(
            personId: ss['personId'] as String,
            estimatedMonthlyBenefitAtFra:
                _m(ss['estimatedMonthlyBenefitAtFra']),
            claimingAge: ss['claimingAge'] as int,
            includeInProjection: ss['includeInProjection'] as bool? ?? true,
          ),
  );
}

IncomeStream _readStream(Map<String, dynamic> j) => IncomeStream(
      id: j['id'] as String,
      personId: j['personId'] as String,
      employerId: j['employerId'] as String?,
      label: j['label'] as String,
      kind: _enum(IncomeKind.values, j['kind']),
      grossAnnualAmount: _m(j['grossAnnualAmount']),
      realGrowthRate: _d(j['realGrowthRate']),
      startYear: j['startYear'] as int?,
      endYear: j['endYear'] as int?,
      startMonth: j['startMonth'] as int?,
      endMonth: j['endMonth'] as int?,
      isFicaSubject: j['isFicaSubject'] as bool,
      isQualifiedBusinessIncome: j['isQualifiedBusinessIncome'] as bool,
      isSpecifiedServiceBusiness:
          j['isSpecifiedServiceBusiness'] as bool? ?? false,
      variability: _enum(IncomeVariability.values, j['variability']),
    );

Account _readAccount(Map<String, dynamic> j) {
  final kindName = j['kind'] as String;
  final kind = AccountKind.values.firstWhere(
    (k) => k.wireName == kindName,
    orElse: () =>
        throw ExportFormatException('"$kindName" is not an account kind'),
  );
  return Account(
    id: j['id'] as String,
    personId: j['personId'] as String,
    label: j['label'] as String,
    kind: kind,
    taxTreatment: _enum(TaxTreatment.values, j['taxTreatment']),
    limitFamily: _enum(LimitFamily.values, j['limitFamily']),
    balance: _m(j['balance']),
    costBasis: _m(j['costBasis']),
    rothContributionBasis: _m(j['rothContributionBasis']),
    rothFirstContributionYear: j['rothFirstContributionYear'] as int?,
    contribution:
        _readContribution(j['contribution'] as Map<String, dynamic>),
    employerId: j['employerId'] as String?,
    allocationMode: _enum(AllocationMode.values, j['allocationMode']),
    assetAllocationId: j['assetAllocationId'] as String?,
    retirementAllocationId: j['retirementAllocationId'] as String?,
    allocationWeights: _list(j['allocationWeights'])
        .map((w) => AllocationWeight(
              assetClassId: w['assetClassId'] as String,
              weight: _d(w['weight']),
            ))
        .toList(),
    isRestrictedPurpose: j['isRestrictedPurpose'] as bool,
    targetBalanceMonths: (j['targetBalanceMonths'] as num?)?.toDouble(),
  );
}

Contribution _readContribution(Map<String, dynamic> j) {
  final m = j['employerMatch'] as Map<String, dynamic>?;
  return Contribution(
    mode: _enum(ContributionMode.values, j['mode']),
    value: _d(j['value']),
    contributionBaseStreamIds:
        ((j['contributionBaseStreamIds'] as List<dynamic>?) ?? const [])
            .cast<String>()
            .toList(),
    employerMatch: m == null
        ? null
        : EmployerMatch(
            formula: _enum(MatchFormula.values, m['formula']),
            matchRate: _d(m['matchRate']),
            matchLimitPercentOfSalary: _d(m['matchLimitPercentOfSalary']),
            tiers: _list(m['tiers'])
                .map((t) => MatchTier(
                      upToPercentOfSalary: _d(t['upToPercentOfSalary']),
                      matchRate: _d(t['matchRate']),
                    ))
                .toList(),
            vestingSchedule:
                _readVesting(m['vestingSchedule'] as Map<String, dynamic>?),
          ),
    reducesFederalTaxableIncome: j['reducesFederalTaxableIncome'] as bool,
    reducesStateTaxableIncome: j['reducesStateTaxableIncome'] as bool,
    reducesFicaWages: j['reducesFicaWages'] as bool,
    startYear: j['startYear'] as int?,
    endYear: j['endYear'] as int?,
    startMonth: j['startMonth'] as int?,
    endMonth: j['endMonth'] as int?,
  );
}

VestingSchedule? _readVesting(Map<String, dynamic>? j) {
  if (j == null) return null;
  return switch (j['kind'] as String) {
    'immediate' => const ImmediateVesting(),
    'cliff' => CliffVesting(j['years'] as int),
    'graded' => GradedVesting(_list(j['schedule'])
        .map((e) => (years: e['years'] as int, vested: _d(e['vested'])))
        .toList()),
    final other => throw ExportFormatException('"$other" is not a vesting kind'),
  };
}

PayrollDeduction _readDeduction(Map<String, dynamic> j) => PayrollDeduction(
      id: j['id'] as String,
      personId: j['personId'] as String,
      label: j['label'] as String,
      kind: _enum(PayrollDeductionKind.values, j['kind']),
      annualAmount: _m(j['annualAmount']),
      reducesFederalTaxableIncome: j['reducesFederalTaxableIncome'] as bool,
      reducesStateTaxableIncome: j['reducesStateTaxableIncome'] as bool,
      reducesFicaWages: j['reducesFicaWages'] as bool,
      expenseCategoryId: j['expenseCategoryId'] as String?,
      startYear: j['startYear'] as int?,
      endYear: j['endYear'] as int?,
      startMonth: j['startMonth'] as int?,
      endMonth: j['endMonth'] as int?,
    );

Asset _readAsset(Map<String, dynamic> j) => Asset(
      id: j['id'] as String,
      householdId: j['householdId'] as String,
      personId: j['personId'] as String?,
      label: j['label'] as String,
      category: _enum(AssetCategory.values, j['category']),
      currentValue: _m(j['currentValue']),
      costBasis: _m(j['costBasis']),
      realAppreciationRate: _d(j['realAppreciationRate']),
      accumulatedDepreciation: _m(j['accumulatedDepreciation']),
      landFraction: _d(j['landFraction']),
      securedByLiabilityId: j['securedByLiabilityId'] as String?,
      acquisitionYear: j['acquisitionYear'] as int?,
      purchaseFundingAccountId: j['purchaseFundingAccountId'] as String?,
      plannedSaleYear: j['plannedSaleYear'] as int?,
      saleProceedsAccountId: j['saleProceedsAccountId'] as String?,
    );

Liability _readLiability(Map<String, dynamic> j) => Liability(
      id: j['id'] as String,
      householdId: j['householdId'] as String,
      personId: j['personId'] as String?,
      label: j['label'] as String,
      kind: _enum(LiabilityKind.values, j['kind']),
      currentBalance: _m(j['currentBalance']),
      interestRate: _d(j['interestRate']),
      monthlyPayment: _m(j['monthlyPayment']),
      monthlyEscrowAmount: _mn(j['monthlyEscrowAmount']),
      monthlyPmiAmount: _mn(j['monthlyPmiAmount']),
      escrowContinuesAfterPayoff: _d(j['escrowContinuesAfterPayoff']),
      extraPrincipalPayment: _m(j['extraPrincipalPayment']),
      originationDate: _date(j['originationDate']),
      termMonths: j['termMonths'] as int,
      securedAssetId: j['securedAssetId'] as String?,
      isTaxDeductibleInterest: j['isTaxDeductibleInterest'] as bool,
    );

ExpenseCategory _readCategory(Map<String, dynamic> j) => ExpenseCategory(
      id: j['id'] as String,
      householdId: j['householdId'] as String,
      label: j['label'] as String,
      metaCategory: _enum(MetaCategory.values, j['metaCategory']),
      defaultRelativeInflation: _d(j['defaultRelativeInflation']),
    );

ExpenseItem _readItem(Map<String, dynamic> j) => ExpenseItem(
      id: j['id'] as String,
      categoryId: j['categoryId'] as String,
      label: j['label'] as String,
      amount: _m(j['amount']),
      frequency: _enum(ExpenseFrequency.values, j['frequency']),
      startYear: j['startYear'] as int?,
      endYear: j['endYear'] as int?,
      startMonth: j['startMonth'] as int?,
      endMonth: j['endMonth'] as int?,
      relativeInflationRate: (j['relativeInflationRate'] as num?)?.toDouble(),
      phase: _enum(ExpensePhase.values, j['phase']),
      postRetirementAmount: _mn(j['postRetirementAmount']),
      housingId: j['housingId'] as String?,
    );

OneTimeEvent _readEvent(Map<String, dynamic> j) => OneTimeEvent(
      id: j['id'] as String,
      householdId: j['householdId'] as String,
      personId: j['personId'] as String?,
      label: j['label'] as String,
      year: j['year'] as int,
      amount: _m(j['amount']),
      kind: _enum(OneTimeEventKind.values, j['kind']),
      accountId: j['accountId'] as String?,
      taxTreatment: _enum(EventTaxTreatment.values, j['taxTreatment']),
    );

Scenario _readScenario(Map<String, dynamic> j) => Scenario(
      id: j['id'] as String,
      householdId: j['householdId'] as String,
      label: j['label'] as String,
      assumptions:
          _readAssumptions(j['assumptions'] as Map<String, dynamic>),
    );

Assumptions _readAssumptions(Map<String, dynamic> j) => Assumptions(
      generalInflationRate: _d(j['generalInflationRate']),
      safeWithdrawalRate: _d(j['safeWithdrawalRate']),
      contributionWaterfall:
          ((j['contributionWaterfall'] as List<dynamic>).cast<String>())
              .map((n) => _enum(WaterfallStep.values, n))
              .toList(),
      withdrawalOrder:
          ((j['withdrawalOrder'] as List<dynamic>).cast<String>())
              .map((n) => _enum(WithdrawalSource.values, n))
              .toList(),
      highInterestDebtThresholdRate: _d(j['highInterestDebtThresholdRate']),
      includeSocialSecurity: j['includeSocialSecurity'] as bool,
      capitalGainsRealizationRate: _d(j['capitalGainsRealizationRate']),
      projectionHorizonAge: j['projectionHorizonAge'] as int,
      acaMagiCeilingPercentOfFpl: _d(j['acaMagiCeilingPercentOfFpl']),
      pmiTerminationLtv: _d(j['pmiTerminationLtv']),
      assetSaleCostRate: _d(j['assetSaleCostRate']),
      assetAppreciationByCategory: j['assetAppreciationByCategory'] == null
          ? Assumptions.defaultAssetAppreciation
          : {
              for (final e in (j['assetAppreciationByCategory']
                      as Map<String, dynamic>)
                  .entries)
                AssetCategory.values.byName(e.key): _d(e.value),
            },
      taxYearId: j['taxYearId'] as String,
    );

AssetClass _readAssetClass(Map<String, dynamic> j) => AssetClass(
      id: j['id'] as String,
      label: _enum(AssetClassLabel.values, j['label']),
      expectedRealReturn: _d(j['expectedRealReturn']),
      pessimisticRealReturn: _d(j['pessimisticRealReturn']),
      optimisticRealReturn: _d(j['optimisticRealReturn']),
      incomeYield: _d(j['incomeYield']),
      qualifiedIncomeFraction: _d(j['qualifiedIncomeFraction']),
    );
