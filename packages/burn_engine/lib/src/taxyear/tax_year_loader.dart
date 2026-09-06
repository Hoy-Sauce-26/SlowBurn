/// Reads a bundled ruleset (§3.12) from the JSON it ships as.
///
/// JSON rather than a Dart constant, because §7 promises that a new tax year is
/// a data change and not a code change. The engine stays pure Dart: the caller
/// hands over decoded JSON, and reading the asset is the app's job.
library;

import 'dart:convert';

import '../enums.dart';
import '../types.dart';
import 'tax_year.dart';

class TaxYearFormatException implements Exception {
  final String message;
  const TaxYearFormatException(this.message);
  @override
  String toString() => 'TaxYearFormatException: $message';
}

TaxYear parseTaxYear(String source) =>
    taxYearFromJson(jsonDecode(source) as Map<String, dynamic>);

TaxYear taxYearFromJson(Map<String, dynamic> j) {
  T need<T>(String key) {
    final v = j[key];
    if (v == null) throw TaxYearFormatException('missing "$key"');
    if (v is! T) {
      throw TaxYearFormatException('"$key" is ${v.runtimeType}, wanted $T');
    }
    return v;
  }

  return TaxYear(
    id: need<String>('id'),
    year: need<int>('year'),
    federalBrackets: _byStatus(need('federalBrackets'), _brackets),
    federalLtcgBrackets: _byStatus(need('federalLtcgBrackets'), _brackets),
    standardDeduction: _byStatus(need('standardDeduction'), _indexed),
    additionalStandardDeductionAge65:
        _indexed(need('additionalStandardDeductionAge65')),
    qbiDeductionRate: _rate(need('qbiDeductionRate')),
    qbiThreshold: _byStatus(need('qbiThreshold'), _indexed),
    studentLoanInterestCap: _indexed(need('studentLoanInterestCap')),
    studentLoanInterestPhaseOut:
        _byStatus(need('studentLoanInterestPhaseOut'), _phaseOut),
    socialSecurityWageBase: _money(need('socialSecurityWageBase')),
    oasdiRate: _rate(need('oasdiRate')),
    medicareRate: _rate(need('medicareRate')),
    seNetEarningsFactor: _rate(need('seNetEarningsFactor')),
    additionalMedicareRate: _rate(need('additionalMedicareRate')),
    additionalMedicareThreshold:
        _byStatus(need('additionalMedicareThreshold'), _indexed),
    niitThreshold: _byStatus(need('niitThreshold'), _indexed),
    niitRate: _rate(need('niitRate')),
    socialSecurityTaxabilityThresholds:
        _byStatus(need('socialSecurityTaxabilityThresholds'), _phaseOut),
    socialSecurityTaxableFractions:
        _fractions(need('socialSecurityTaxableFractions')),
    socialSecurityFraByBirthYear:
        _intMap(need('socialSecurityFraByBirthYear'), (v) => v as int),
    claimingAdjustment: _claiming(need('claimingAdjustment')),
    contributionLimits: _limits(need('contributionLimits')),
    rothCatchUpWageThreshold: _money(need('rothCatchUpWageThreshold')),
    annualAdditions415c: _money(need('annualAdditions415c')),
    compensationLimit401a17: _money(need('compensationLimit401a17')),
    rothIraIncomeLimit: _byStatus(need('rothIraIncomeLimit'), _phaseOut),
    iraDeductibilityPhaseOut: _byStatus(
      need('iraDeductibilityPhaseOut'),
      (v) => (v as Map<String, dynamic>)
          .map((k, p) => MapEntry(k, _phaseOut(p))),
    ),
    earlyWithdrawalPenaltyRate: _rate(need('earlyWithdrawalPenaltyRate')),
    hsaNonMedicalPenaltyRate: _rate(need('hsaNonMedicalPenaltyRate')),
    rmdAgeByBirthYear: _intMap(need('rmdAgeByBirthYear'), (v) => v as int),
    rmdDivisorTable:
        _intMap(need('rmdDivisorTable'), (v) => (v as num).toDouble()),
    childTaxCreditPerChild: _money(need('childTaxCreditPerChild')),
    childTaxCreditPhaseOutThreshold:
        _byStatus(need('childTaxCreditPhaseOutThreshold'), _indexed),
    childTaxCreditPhaseOutPerThousand:
        _money(need('childTaxCreditPhaseOutPerThousand')),
    childTaxCreditPhaseOutStep: _money(need('childTaxCreditPhaseOutStep')),
    childTaxCreditQualifyingAge: need<int>('childTaxCreditQualifyingAge'),
    childTaxCreditRefundablePerChild:
        _money(need('childTaxCreditRefundablePerChild')),
    childTaxCreditRefundableRate: _rate(need('childTaxCreditRefundableRate')),
    childTaxCreditRefundableEarnedIncomeFloor:
        _indexed(need('childTaxCreditRefundableEarnedIncomeFloor')),
    federalPovertyLevel: (need<Map<String, dynamic>>('federalPovertyLevel'))
        .map((state, table) =>
            MapEntry(state, _intMap(table, (v) => _money(v)))),
    federalPovertyLevelIncrement: _money(need('federalPovertyLevelIncrement')),
    acaApplicablePercentageTable:
        (need<List<dynamic>>('acaApplicablePercentageTable'))
            .map((p) => ApplicablePercentagePoint(
                  fplPercent: (p['fplPercent'] as num).toDouble(),
                  applicablePercent: _rate(p['applicablePercent']),
                ))
            .toList(),
    acaMinimumFplPercent: (need<num>('acaMinimumFplPercent')).toDouble(),
    acaMaximumFplPercent: (j['acaMaximumFplPercent'] as num?)?.toDouble(),
    acaBenchmarkPremiumByAge:
        _intMap(need('acaBenchmarkPremiumByAge'), (v) => _money(v)),
    irmaaBrackets: _byStatus(
      need('irmaaBrackets'),
      (v) => (v as List<dynamic>)
          .map((b) => IrmaaBracket(
                magiThreshold: _money(b['magiThreshold']),
                partBPremium: _money(b['partBPremium']),
                partDSurcharge: _money(b['partDSurcharge']),
              ))
          .toList(),
    ),
    section121Exclusion: _byStatus(need('section121Exclusion'), _indexed),
    unrecapturedSection1250Rate: _rate(need('unrecapturedSection1250Rate')),
    residentialDepreciationYears:
        (need<num>('residentialDepreciationYears')).toDouble(),
    stateRules: _jurisdictions(need('stateRules')),
    localRules: _jurisdictions(need('localRules')),
  );
}

/// Money arrives as whole cents, matching invariant 10. A fractional cent in
/// the bundle is a mistake in the bundle, so it is refused rather than rounded.
Money _money(dynamic v) {
  if (v is int) return Money(v);
  throw TaxYearFormatException('money must be integer cents, got $v');
}

Rate _rate(dynamic v) => (v as num).toDouble();

Indexed _indexed(dynamic v) {
  final m = v as Map<String, dynamic>;
  final amount = _money(m['value']);
  return (m['indexed'] as bool? ?? true)
      ? Indexed.indexed(amount)
      : Indexed.fixed(amount);
}

List<TaxBracket> _brackets(dynamic v) => (v as List<dynamic>)
    .map((b) => TaxBracket(
          upTo: b['upTo'] == null ? null : _money(b['upTo']),
          rate: _rate(b['rate']),
        ))
    .toList();

PhaseOut _phaseOut(dynamic v) => PhaseOut(
      lower: _money(v['lower']),
      upper: _money(v['upper']),
    );

TaxableFractions _fractions(dynamic v) => TaxableFractions(
      half: _rate(v['half']),
      cap: _rate(v['cap']),
    );

ClaimingAdjustment _claiming(dynamic v) => ClaimingAdjustment(
      earlyFirstMonths: v['earlyFirstMonths'] as int,
      earlyRate: _rate(v['earlyRate']),
      earlyRateBeyond: _rate(v['earlyRateBeyond']),
      delayedRate: _rate(v['delayedRate']),
    );

Map<FilingStatus, T> _byStatus<T>(dynamic v, T Function(dynamic) read) {
  final m = v as Map<String, dynamic>;
  return {
    for (final status in FilingStatus.values)
      if (m.containsKey(status.name)) status: read(m[status.name]!),
  };
}

Map<int, T> _intMap<T>(dynamic v, T Function(dynamic) read) =>
    (v as Map<String, dynamic>).map(
        (k, value) => MapEntry(int.parse(k), read(value)));

Map<LimitFamily, ContributionLimit> _limits(dynamic v) {
  final m = v as Map<String, dynamic>;
  return {
    for (final family in LimitFamily.values)
      if (m.containsKey(family.name))
        family: ContributionLimit(
          annual: m[family.name]['annual'] == null
              ? null
              : _money(m[family.name]['annual']),
          selfOnly: m[family.name]['selfOnly'] == null
              ? null
              : _money(m[family.name]['selfOnly']),
          family: m[family.name]['family'] == null
              ? null
              : _money(m[family.name]['family']),
          rate: m[family.name]['rate'] == null
              ? null
              : _rate(m[family.name]['rate']),
          catchUpTiers: ((m[family.name]['catchUpTiers'] as List<dynamic>?) ??
                  const [])
              .map((t) => CatchUpTier(
                    fromAge: t['fromAge'] as int,
                    toAge: t['toAge'] as int?,
                    amount: _money(t['amount']),
                  ))
              .toList(),
        ),
  };
}

Map<String, JurisdictionRules> _jurisdictions(dynamic v) =>
    (v as Map<String, dynamic>).map((code, r) => MapEntry(
          code,
          JurisdictionRules(
            code: code,
            brackets:
                _jurisdictionByStatus<List<TaxBracket>>(r['brackets'], _brackets),
            flatRate: r['flatRate'] == null ? null : _rate(r['flatRate']),
            standardDeduction:
                _jurisdictionByStatus<Money>(r['standardDeduction'], _money),
            personalExemption:
                _jurisdictionByStatus<Money>(r['personalExemption'], _money),
            conformsToPreTaxDeferrals:
                r['conformsToPreTaxDeferrals'] as bool? ?? true,
            retirementIncomeExclusion:
                _jurisdictionByStatus<Money>(
                    r['retirementIncomeExclusion'], _money),
          ),
        ));

/// A jurisdiction figure is either one value for everybody, or a `single` and
/// a `married` pair. Filing separately and heads of household follow the single
/// schedule, which is what most states do and the conservative reading where
/// they do not.
Map<FilingStatus, T> _jurisdictionByStatus<T>(dynamic v, T Function(dynamic) parse) {
  if (v == null) return const {};
  if (v is! Map<String, dynamic>) {
    final one = parse(v);
    return {for (final s in FilingStatus.values) s: one};
  }
  if (!v.containsKey('single')) {
    throw const TaxYearFormatException(
        'a jurisdiction figure split by status needs at least "single"');
  }
  final single = parse(v['single']);
  final married = v['married'] == null ? single : parse(v['married']);
  return {
    FilingStatus.single: single,
    FilingStatus.marriedFilingSeparately: single,
    FilingStatus.headOfHousehold: single,
    FilingStatus.marriedFilingJointly: married,
    FilingStatus.qualifyingSurvivingSpouse: married,
  };
}
