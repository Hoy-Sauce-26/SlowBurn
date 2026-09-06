/// §4.1 and §4.2. What a person earned, and what payroll tax it costs.
///
/// Everything here is **per person**, because the wage base, the contribution
/// limits and the age gates are all per individual, and computing them on a
/// household total gives wrong answers (§3.1). The one exception is the
/// Additional Medicare Tax, which §4.2 assesses per `TaxUnit` and which lives
/// in [additionalMedicare] below.
library;

import '../entities/account.dart';
import '../entities/household.dart';
import '../entities/income.dart';
import '../entities/person.dart';
import '../enums.dart';
import '../taxyear/tax_year.dart';
import '../types.dart';

/// One person's wages and payroll tax for one projected year.
class PersonWages {
  final Id personId;

  /// W-2 wages, bonus and RSU vesting (§4.1).
  final Money wageIncome;

  /// Schedule C net profit, before the 92.35% factor (§3.4).
  final Money seEarnings;

  /// Cafeteria-plan money that never reached FICA-subject pay (§4.1).
  final Money ficaExempt;

  /// FICA-subject pay less [ficaExempt], floored at zero (§4.1).
  final Money ficaWages;

  final Money seNetEarnings;

  final Money oasdi;
  final Money medicare;
  final Money seOasdi;
  final Money seMedicare;

  /// Half of [seTax], and above the line (§4.2). Excludes the Additional
  /// Medicare Tax, which is not deductible.
  final Money seDeduction;

  const PersonWages({
    required this.personId,
    required this.wageIncome,
    required this.seEarnings,
    required this.ficaExempt,
    required this.ficaWages,
    required this.seNetEarnings,
    required this.oasdi,
    required this.medicare,
    required this.seOasdi,
    required this.seMedicare,
    required this.seDeduction,
  });

  Money get seTax => seOasdi + seMedicare;

  /// Everything this person owes in payroll tax, before the per-TaxUnit
  /// Additional Medicare Tax is added in §4.3.6.
  Money get payrollTax => oasdi + medicare + seTax;

  /// What the Additional Medicare threshold is measured against (§4.2).
  Money get combinedMedicareWages => ficaWages + seNetEarnings;
}

/// §4.1 and §4.2 for one person in one year.
PersonWages computeWages(
  Person person, {
  required Household household,
  required TaxYear taxYear,
  required int year,
  required int currentYear,
  /// Elections settled by sweep 1 before this runs (§4.4.3), keyed by account
  /// id. Absent means the account's committed contribution stands.
  Map<Id, Money> resolvedContributions = const {},
}) {
  final streams = household.streamsFor(person.id).toList();

  Money sumStreams(bool Function(IncomeStream) predicate) => sumMoney(
        streams
            .where(predicate)
            .map((s) => s.resolvedAmount(year, currentYear: currentYear)),
      );

  // `kind` places a stream for income tax; `isFicaSubject` decides only whether
  // it pays FICA. Reading the flag in both places would count an overridden
  // `other` stream twice and drop an overridden `w2Wages` stream entirely.
  final wageIncome = sumStreams((s) =>
      s.kind == IncomeKind.w2Wages ||
      s.kind == IncomeKind.bonus ||
      s.kind == IncomeKind.rsuVesting);
  final seEarnings = sumStreams((s) => s.kind == IncomeKind.selfEmployment);
  final ficaSubjectPay = sumStreams((s) => s.isFicaSubject);

  // Cafeteria-plan money comes in two shapes: an HSA deferral is money saved
  // and belongs to an Account, a premium or FSA election is money spent with no
  // balance to attach to. Both reduce FICA wages identically (§4.1).
  final exemptContributions = sumMoney(
    household.accountsFor(person.id).where((a) => a.contribution.reducesFicaWages).map(
          (a) => resolvedContributions[a.id] ??
              _committedAmount(a, household, year, currentYear),
        ),
  );
  final exemptDeductions = sumMoney(
    household.payrollDeductions
        .where((d) => d.personId == person.id && d.reducesFicaWages)
        .map((d) => d.resolvedAmount(year)),
  );
  final ficaExempt = exemptContributions + exemptDeductions;

  // §125 and §132(f) deductions can exceed FICA-subject pay, which is ordinary
  // for a part-time job carrying family coverage. Unfloored, oasdi and medicare
  // would run negative; the unused excess carries nowhere.
  final ficaWages = (ficaSubjectPay - ficaExempt).orZeroIfNegative;

  final seNetEarnings = seEarnings * taxYear.seNetEarningsFactor;

  final oasdi =
      minMoney(ficaWages, taxYear.socialSecurityWageBase) * taxYear.oasdiRate;
  final medicare = ficaWages * taxYear.medicareRate;

  // The SE OASDI cap is shared with W-2 wages, per person: a second independent
  // cap would overtax anyone with a job and a side business (§4.2).
  final remainingOasdiRoom =
      (taxYear.socialSecurityWageBase - ficaWages).orZeroIfNegative;
  final seOasdiBase = minMoney(seNetEarnings, remainingOasdiRoom);
  final seOasdi = seOasdiBase * taxYear.seOasdiRate;
  final seMedicare = seNetEarnings * taxYear.seMedicareRate;

  return PersonWages(
    personId: person.id,
    wageIncome: wageIncome,
    seEarnings: seEarnings,
    ficaExempt: ficaExempt,
    ficaWages: ficaWages,
    seNetEarnings: seNetEarnings,
    oasdi: oasdi,
    medicare: medicare,
    seOasdi: seOasdi,
    seMedicare: seMedicare,
    seDeduction: (seOasdi + seMedicare) / 2,
  );
}

/// What an account's committed contribution asks for, before any cap (§3.4.1).
Money _committedAmount(
  Account account,
  Household household,
  int year,
  int currentYear,
) {
  final c = account.contribution;
  if (c.mode == ContributionMode.fixedAmount) {
    return c.uncappedAmount(year, base: Money.zero);
  }
  final base = sumMoney(
    c.contributionBaseStreamIds
        .map((id) =>
            household.incomeStreams.where((s) => s.id == id).firstOrNull)
        .whereType<IncomeStream>()
        .map((s) => s.resolvedAmount(year, currentYear: currentYear)),
  );
  return c.uncappedAmount(year, base: base);
}

/// §4.2's Additional Medicare Tax, per **TaxUnit**: the threshold is a
/// filing-status figure applied to combined wages *and* self-employment income.
Money additionalMedicare(
  Iterable<PersonWages> unitMembers, {
  required TaxYear taxYear,
  required FilingStatus status,
  required int year,
  required int currentYear,
  required Rate inflation,
}) {
  final combined =
      sumMoney(unitMembers.map((w) => w.combinedMedicareWages));
  final threshold = taxYear.additionalMedicareThreshold[status]!
      .realValueIn(year, currentYear: currentYear, inflation: inflation);
  return (combined - threshold).orZeroIfNegative *
      taxYear.additionalMedicareRate;
}
