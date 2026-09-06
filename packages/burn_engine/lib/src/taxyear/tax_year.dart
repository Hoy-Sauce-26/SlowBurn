/// §3.12. The bundled, versioned, immutable ruleset a projection runs under.
///
/// Every statutory rate and threshold lives here, including the ones statute
/// has never restated: [Indexed.fixed] marks a figure that does not index, and
/// it stays data all the same. The only statutory numbers left in code are the
/// ages 59½ and 65 (§3.12).
library;

import '../enums.dart';
import '../types.dart';

/// A figure and whether statute indexes it (§7.4).
///
/// A fixed figure must be **deflated** each projected year by
/// `generalInflationRate`, or an increasing share of households silently stops
/// crossing it.
class Indexed {
  final Money value;
  final bool indexed;

  const Indexed.indexed(this.value) : indexed = true;
  const Indexed.fixed(this.value) : indexed = false;

  /// This threshold in real terms for a projected year (§7.4).
  Money realValueIn(int year,
      {required int currentYear, required Rate inflation}) {
    if (indexed) return value;
    var deflated = value;
    for (var y = currentYear; y < year; y++) {
      deflated = deflated / (1 + inflation);
    }
    return deflated;
  }
}

/// One rate band of a progressive schedule. [upTo] is null on the top band.
class TaxBracket {
  final Money? upTo;
  final Rate rate;
  const TaxBracket({required this.upTo, required this.rate});
}

/// A `{lower, upper}` range a benefit or deduction phases out across.
class PhaseOut {
  final Money lower;
  final Money upper;
  const PhaseOut({required this.lower, required this.upper});

  /// How far into the phase-out [magi] sits, clamped to [0, 1].
  double fractionAt(Money magi) {
    if (upper <= lower) return magi >= upper ? 1 : 0;
    final raw = (magi - lower).ratioTo(upper - lower);
    return raw < 0 ? 0 : (raw > 1 ? 1 : raw);
  }
}

/// One catch-up tier, applying to ages in `[fromAge, toAge]` (§3.4.2).
class CatchUpTier {
  final int fromAge;
  final int? toAge;
  final Money amount;
  const CatchUpTier({required this.fromAge, this.toAge, required this.amount});

  bool coversAge(int age) => age >= fromAge && (toAge == null || age <= toAge!);
}

/// The limits governing one [LimitFamily] (§3.4.2).
class ContributionLimit {
  /// The base annual limit. Null where the family has no federal annual limit,
  /// as `education` and `none` do not.
  final Money? annual;

  /// The self and family amounts, for `hsa` only.
  final Money? selfOnly;
  final Money? family;

  /// The statutory rate, for `sep` only.
  final Rate? rate;

  final List<CatchUpTier> catchUpTiers;

  const ContributionLimit({
    this.annual,
    this.selfOnly,
    this.family,
    this.rate,
    this.catchUpTiers = const [],
  });

  /// The catch-up a person of [age] is owed, or zero.
  Money catchUpFor(int age) {
    for (final tier in catchUpTiers) {
      if (tier.coversAge(age)) return tier.amount;
    }
    return Money.zero;
  }
}

/// §3.11's claiming reduction and delayed credit, per month.
class ClaimingAdjustment {
  final int earlyFirstMonths;
  final Rate earlyRate;
  final Rate earlyRateBeyond;
  final Rate delayedRate;

  const ClaimingAdjustment({
    required this.earlyFirstMonths,
    required this.earlyRate,
    required this.earlyRateBeyond,
    required this.delayedRate,
  });
}

/// The §86 inclusion fractions (§4.3.1).
class TaxableFractions {
  final Rate half;
  final Rate cap;
  const TaxableFractions({required this.half, required this.cap});
}

/// One point on the ACA applicable-percentage schedule (§3.12).
///
/// Two points sharing an [fplPercent] express a step, which is what a schedule
/// with a discontinuity needs.
class ApplicablePercentagePoint {
  final double fplPercent;
  final Rate applicablePercent;
  const ApplicablePercentagePoint({
    required this.fplPercent,
    required this.applicablePercent,
  });
}

/// One IRMAA tier: monthly, per person, against MAGI from two years prior.
class IrmaaBracket {
  final Money magiThreshold;
  final Money partBPremium;
  final Money partDSurcharge;
  const IrmaaBracket({
    required this.magiThreshold,
    required this.partBPremium,
    required this.partDSurcharge,
  });
}

/// A state's or locality's own schedule (§3.12).
class JurisdictionRules {
  final String code;

  /// Schedules by filing status. States that publish one schedule for everyone
  /// carry the same list under every status, and a status with no schedule of
  /// its own falls back to the single one (§4.3.6).
  final Map<FilingStatus, List<TaxBracket>> brackets;
  final Rate? flatRate;
  final Map<FilingStatus, Money> standardDeduction;
  final Map<FilingStatus, Money> personalExemption;

  /// Whether this jurisdiction follows the federal treatment of pre-tax
  /// deferrals. False for Pennsylvania and similar (§4.3.3).
  final bool conformsToPreTaxDeferrals;

  final Map<FilingStatus, Money> retirementIncomeExclusion;

  const JurisdictionRules({
    required this.code,
    this.brackets = const {},
    this.flatRate,
    this.standardDeduction = const {},
    this.personalExemption = const {},
    this.conformsToPreTaxDeferrals = true,
    this.retirementIncomeExclusion = const {},
  });

  List<TaxBracket> bracketsFor(FilingStatus status) =>
      brackets[status] ?? brackets[FilingStatus.single] ?? const [];

  Money standardDeductionFor(FilingStatus status) => _amount(standardDeduction, status);
  Money personalExemptionFor(FilingStatus status) => _amount(personalExemption, status);
  Money retirementIncomeExclusionFor(FilingStatus status) =>
      _amount(retirementIncomeExclusion, status);

  static Money _amount(Map<FilingStatus, Money> by, FilingStatus status) =>
      by[status] ?? by[FilingStatus.single] ?? Money.zero;

  bool get leviesNoIncomeTax =>
      (flatRate ?? 0) == 0 && brackets.values.every((b) => b.isEmpty);
}

/// The whole ruleset for one tax year.
class TaxYear {
  final Id id;
  final int year;

  // Federal income tax
  final Map<FilingStatus, List<TaxBracket>> federalBrackets;
  final Map<FilingStatus, List<TaxBracket>> federalLtcgBrackets;
  final Map<FilingStatus, Indexed> standardDeduction;
  final Indexed additionalStandardDeductionAge65;

  // §199A
  final Rate qbiDeductionRate;
  final Map<FilingStatus, Indexed> qbiThreshold;

  // Above the line
  final Indexed studentLoanInterestCap;
  final Map<FilingStatus, PhaseOut> studentLoanInterestPhaseOut;

  // Payroll
  final Money socialSecurityWageBase;
  final Rate oasdiRate;
  final Rate medicareRate;
  final Rate seNetEarningsFactor;
  final Rate additionalMedicareRate;
  final Map<FilingStatus, Indexed> additionalMedicareThreshold;

  // Investment
  final Map<FilingStatus, Indexed> niitThreshold;
  final Rate niitRate;

  // Social Security
  final Map<FilingStatus, PhaseOut> socialSecurityTaxabilityThresholds;
  final TaxableFractions socialSecurityTaxableFractions;
  final Map<int, int> socialSecurityFraByBirthYear;
  final ClaimingAdjustment claimingAdjustment;

  // Contributions
  final Map<LimitFamily, ContributionLimit> contributionLimits;
  final Money rothCatchUpWageThreshold;
  final Money annualAdditions415c;
  final Money compensationLimit401a17;
  final Map<FilingStatus, PhaseOut> rothIraIncomeLimit;
  final Map<FilingStatus, Map<String, PhaseOut>> iraDeductibilityPhaseOut;

  // Withdrawals
  final Rate earlyWithdrawalPenaltyRate;
  final Rate hsaNonMedicalPenaltyRate;
  final Map<int, int> rmdAgeByBirthYear;
  final Map<int, double> rmdDivisorTable;

  // Child Tax Credit
  final Money childTaxCreditPerChild;
  final Map<FilingStatus, Indexed> childTaxCreditPhaseOutThreshold;
  final Money childTaxCreditPhaseOutPerThousand;
  final Money childTaxCreditPhaseOutStep;
  final int childTaxCreditQualifyingAge;
  final Money childTaxCreditRefundablePerChild;
  final Rate childTaxCreditRefundableRate;
  final Indexed childTaxCreditRefundableEarnedIncomeFloor;

  // ACA and Medicare
  final Map<String, Map<int, Money>> federalPovertyLevel;
  final Money federalPovertyLevelIncrement;
  final List<ApplicablePercentagePoint> acaApplicablePercentageTable;
  final double acaMinimumFplPercent;
  final double? acaMaximumFplPercent;
  final Map<int, Money> acaBenchmarkPremiumByAge;
  final Map<FilingStatus, List<IrmaaBracket>> irmaaBrackets;

  // Property
  final Map<FilingStatus, Indexed> section121Exclusion;
  final Rate unrecapturedSection1250Rate;
  final double residentialDepreciationYears;

  // Jurisdictions
  final Map<String, JurisdictionRules> stateRules;
  final Map<String, JurisdictionRules> localRules;

  const TaxYear({
    required this.id,
    required this.year,
    required this.federalBrackets,
    required this.federalLtcgBrackets,
    required this.standardDeduction,
    required this.additionalStandardDeductionAge65,
    required this.qbiDeductionRate,
    required this.qbiThreshold,
    required this.studentLoanInterestCap,
    required this.studentLoanInterestPhaseOut,
    required this.socialSecurityWageBase,
    required this.oasdiRate,
    required this.medicareRate,
    required this.seNetEarningsFactor,
    required this.additionalMedicareRate,
    required this.additionalMedicareThreshold,
    required this.niitThreshold,
    required this.niitRate,
    required this.socialSecurityTaxabilityThresholds,
    required this.socialSecurityTaxableFractions,
    required this.socialSecurityFraByBirthYear,
    required this.claimingAdjustment,
    required this.contributionLimits,
    required this.rothCatchUpWageThreshold,
    required this.annualAdditions415c,
    required this.compensationLimit401a17,
    required this.rothIraIncomeLimit,
    required this.iraDeductibilityPhaseOut,
    required this.earlyWithdrawalPenaltyRate,
    required this.hsaNonMedicalPenaltyRate,
    required this.rmdAgeByBirthYear,
    required this.rmdDivisorTable,
    required this.childTaxCreditPerChild,
    required this.childTaxCreditPhaseOutThreshold,
    required this.childTaxCreditPhaseOutPerThousand,
    required this.childTaxCreditPhaseOutStep,
    required this.childTaxCreditQualifyingAge,
    required this.childTaxCreditRefundablePerChild,
    required this.childTaxCreditRefundableRate,
    required this.childTaxCreditRefundableEarnedIncomeFloor,
    required this.federalPovertyLevel,
    required this.federalPovertyLevelIncrement,
    required this.acaApplicablePercentageTable,
    required this.acaMinimumFplPercent,
    this.acaMaximumFplPercent,
    required this.acaBenchmarkPremiumByAge,
    required this.irmaaBrackets,
    required this.section121Exclusion,
    required this.unrecapturedSection1250Rate,
    required this.residentialDepreciationYears,
    required this.stateRules,
    required this.localRules,
  });

  /// The self-employment rates, **derived** as exactly twice the employee
  /// rates, which is the meaning of "pays both halves" and removes any way for
  /// the two to drift apart across tax-year updates (§4.2).
  Rate get seOasdiRate => oasdiRate * 2;
  Rate get seMedicareRate => medicareRate * 2;

  /// The RMD age for someone born in [birthYear], saturating at the table's
  /// published ends rather than running off either of them (§3.12).
  ///
  /// A birth year below the first row is an earlier cohort whose age statute
  /// has already settled; one above the last is a later cohort statute has not
  /// legislated yet, and the newest published rule is the best guess for both.
  int? rmdAgeFor(int birthYear) {
    if (rmdAgeByBirthYear.containsKey(birthYear)) {
      return rmdAgeByBirthYear[birthYear];
    }
    final years = rmdAgeByBirthYear.keys.toList()..sort();
    if (years.isEmpty) return null;
    if (birthYear < years.first) return rmdAgeByBirthYear[years.first];
    return rmdAgeByBirthYear[years.last];
  }

  /// The RMD divisor for [age], saturating at the table's last published row
  /// rather than running off the end (§3.12).
  double rmdDivisorFor(int age) {
    if (rmdDivisorTable.containsKey(age)) return rmdDivisorTable[age]!;
    final ages = rmdDivisorTable.keys.toList()..sort();
    if (ages.isEmpty) return 1;
    if (age < ages.first) return rmdDivisorTable[ages.first]!;
    return rmdDivisorTable[ages.last]!;
  }

  /// The poverty line for a tax unit of [size] in [stateCode], extended past
  /// the published table by its own increment (§3.12).
  Money povertyLevel(String stateCode, int size) {
    final table = federalPovertyLevel[stateCode] ?? federalPovertyLevel['US']!;
    if (table.containsKey(size)) return table[size]!;
    final sizes = table.keys.toList()..sort();
    final largest = sizes.last;
    return table[largest]! + federalPovertyLevelIncrement * (size - largest);
  }
}
