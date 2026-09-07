/// §4.3.1 and §4.3.2. Everything a `TaxUnit` received, down to taxable income.
///
/// Per **TaxUnit**, and every sum here is scoped to one: §4.4's are per
/// household, and mixing the two is how one return's income reaches another's
/// brackets.
library;

import '../entities/account.dart';
import '../entities/assumptions.dart';
import '../entities/household.dart';
import '../entities/income.dart';
import '../entities/person.dart';
import '../enums.dart';
import '../taxyear/tax_year.dart';
import '../types.dart';
import 'allocation.dart';
import 'social_security.dart';
import 'wages.dart';

/// What §6 and §8.4 hand the tax computation, and what Stage 2 leaves at zero.
///
/// These are genuinely outputs of the loop rather than of the household: an RMD
/// is taken at the top of the year, a draw's realised gains depend on the draw,
/// and an asset sale's taxable gain is fixed when §6 reaches the sale year.
class YearInputs {
  /// Forced distributions, already summed for this tax unit (§8.4.2).
  final Money rmdIncome;

  /// Gains realised by whatever was drawn this year (§8.4.1).
  final Money realizedGainsOnDraws;

  /// Taxable gain on this tax unit's asset sales, net of exclusion (§3.5).
  final Money assetSaleTaxableGain;

  /// Unrecaptured §1250 gain from those sales, taxed at its own flat rate.
  final Money assetSaleRecapture;

  /// Depreciation accrued this year on held investment property (§3.5).
  final Money annualDepreciation;

  /// This year's deductible interest on student loans (§3.6).
  final Money studentLoanInterestPaid;

  /// What each account's contribution actually put in, after sweep 1 and the
  /// waterfall settled (§4.4). Absent means the committed amount stands.
  final Map<Id, Money> resolvedContributions;

  const YearInputs({
    this.rmdIncome = Money.zero,
    this.realizedGainsOnDraws = Money.zero,
    this.assetSaleTaxableGain = Money.zero,
    this.assetSaleRecapture = Money.zero,
    this.annualDepreciation = Money.zero,
    this.studentLoanInterestPaid = Money.zero,
    this.resolvedContributions = const {},
  });
}

/// §4.3.1 and §4.3.2, for one tax unit in one year.
class TaxableIncome {
  final Money ssBenefits;
  final Money rentalIncome;
  final Money taxableRental;
  final Money pensionIncome;
  final Money otherStreamIncome;
  final Money rmdIncome;

  final Money inAccountInvestmentIncome;
  final Money qualifiedDividends;
  final Money ordinaryInAccountIncome;

  final Money realizedLongTermGains;
  final Money realizedShortTermGains;

  final Money deductibleStudentLoanInterest;

  /// MAGI computed **before** the two deductions it gates, which is what keeps
  /// the computation acyclic (§4.3.1).
  final Money preDeductionMagi;

  /// How much of a traditional IRA contribution survives the phase-out.
  final double deductibleIraPortion;

  final Money nonSSIncome;
  final Money provisionalIncome;
  final Money taxableSS;

  final Money federalAgi;
  final Money deduction;
  final Money seniorDeduction;
  final Money taxableBeforeQbi;
  final Money qbi;
  final Money qbiDeduction;
  final Money fedTaxable;

  const TaxableIncome({
    required this.ssBenefits,
    required this.rentalIncome,
    required this.taxableRental,
    required this.pensionIncome,
    required this.otherStreamIncome,
    required this.rmdIncome,
    required this.inAccountInvestmentIncome,
    required this.qualifiedDividends,
    required this.ordinaryInAccountIncome,
    required this.realizedLongTermGains,
    required this.realizedShortTermGains,
    required this.deductibleStudentLoanInterest,
    required this.preDeductionMagi,
    required this.deductibleIraPortion,
    required this.nonSSIncome,
    required this.provisionalIncome,
    required this.taxableSS,
    required this.federalAgi,
    required this.deduction,
    required this.seniorDeduction,
    required this.taxableBeforeQbi,
    required this.qbi,
    required this.qbiDeduction,
    required this.fedTaxable,
  });

  /// The preferential slice, which §4.3.3 stacks above ordinary income.
  Money get netCapitalGain => realizedLongTermGains + qualifiedDividends;
}

TaxableIncome computeTaxableIncome(
  TaxUnit unit, {
  required Household household,
  required Assumptions assumptions,
  required TaxYear taxYear,
  required Map<Id, AssetClass> assetClasses,
  required List<PersonWages> wages,
  required int year,
  required int currentYear,

  /// Null while §8.2 is still looking for one. What it changes here is which
  /// allocation an account is throwing off income from (§3.9).
  int? retirementYear,
  YearInputs inputs = const YearInputs(),
}) {
  final retired = retirementYear != null && year >= retirementYear;
  final people = household.peopleIn(unit).toList();
  final personIds = {for (final p in people) p.id};
  final unitWages =
      wages.where((w) => personIds.contains(w.personId)).toList();
  final inflation = assumptions.generalInflationRate;

  Money threshold(Indexed i) =>
      i.realValueIn(year, currentYear: currentYear, inflation: inflation);

  // --- income the unit received -------------------------------------------
  final ssBenefits = assumptions.includeSocialSecurity
      ? sumMoney(people
          .where((p) => benefitCountsIn(p, year,
              includeSocialSecurity: assumptions.includeSocialSecurity))
          .map((p) => adjustedMonthlyBenefit(p.socialSecurity!,
                  birthDate: p.birthDate, taxYear: taxYear) *
              12))
      : Money.zero;

  Money streamsOfKind(IncomeKind kind) => sumMoney(household.incomeStreams
      .where((s) => personIds.contains(s.personId) && s.kind == kind)
      .map((s) => s.resolvedAmount(year, currentYear: currentYear)));

  final rentalIncome = streamsOfKind(IncomeKind.rentalNet);
  // Cash flow keeps the undepreciated figure; only the tax measure is net.
  final taxableRental =
      (rentalIncome - inputs.annualDepreciation).orZeroIfNegative;
  final pensionIncome = streamsOfKind(IncomeKind.pension);
  final otherStreamIncome = streamsOfKind(IncomeKind.other);

  // Only taxable accounts throw off currently-taxable income: distributions
  // inside the other wrappers are not taxed in the year received, which is the
  // entire point of them (§4.3.1).
  final taxableAccounts = household.accounts
      .where((a) =>
          personIds.contains(a.personId) &&
          a.taxTreatment == TaxTreatment.taxable)
      .toList();
  final inAccountInvestmentIncome = sumMoney(taxableAccounts.map(
      (a) => a.balance * blendedIncomeYield(a, assetClasses, retired: retired)));
  final qualifiedDividends = sumMoney(taxableAccounts.map((a) =>
      a.balance *
      (blendedIncomeYield(a, assetClasses, retired: retired) *
          blendedQualifiedIncomeFraction(a, assetClasses, retired: retired))));
  final ordinaryInAccountIncome =
      inAccountInvestmentIncome - qualifiedDividends;

  Money eventsTreated(EventTaxTreatment treatment) => sumMoney(household
      .oneTimeEvents
      .where((e) =>
          e.year == year &&
          e.taxTreatment == treatment &&
          _reachesUnit(e.personId, unit, household))
      .map((e) => e.amount));

  final realizedLongTermGains = sumMoney(taxableAccounts.map((a) =>
          (a.balance - a.costBasis).orZeroIfNegative *
          assumptions.capitalGainsRealizationRate)) +
      eventsTreated(EventTaxTreatment.capitalGainLongTerm) +
      inputs.assetSaleTaxableGain +
      inputs.realizedGainsOnDraws;
  final realizedShortTermGains =
      eventsTreated(EventTaxTreatment.capitalGainShortTerm);

  // --- the two deductions that gate on MAGI -------------------------------
  final wageIncome = sumMoney(unitWages.map((w) => w.wageIncome));
  final seEarnings = sumMoney(unitWages.map((w) => w.seEarnings));
  final seDeduction = sumMoney(unitWages.map((w) => w.seDeduction));
  final ordinaryEvents = eventsTreated(EventTaxTreatment.ordinaryIncome);

  final payrollDeductions = sumMoney(household.payrollDeductions
      .where((d) =>
          personIds.contains(d.personId) && d.reducesFederalTaxableIncome)
      .map((d) => d.resolvedAmount(year)));

  final unitAccounts =
      household.accounts.where((a) => personIds.contains(a.personId)).toList();

  Money contributionOf(Account a) =>
      inputs.resolvedContributions[a.id] ??
      resolveCommittedContribution(a, household, year, currentYear);

  // preDeductionMagi is nonSSIncome without the two deductions it gates: no
  // student-loan interest, and traditional IRA contributions not yet taken.
  final nonIraPreTax = sumMoney(unitAccounts
      .where((a) =>
          a.contribution.reducesFederalTaxableIncome &&
          a.kind != AccountKind.traditionalIra)
      .map(contributionOf));

  final incomeBeforeDeductions = wageIncome +
      seEarnings -
      seDeduction +
      taxableRental +
      pensionIncome +
      otherStreamIncome +
      ordinaryInAccountIncome +
      inputs.rmdIncome +
      ordinaryEvents +
      realizedShortTermGains +
      realizedLongTermGains +
      qualifiedDividends;

  final preDeductionMagi =
      incomeBeforeDeductions - nonIraPreTax - payrollDeductions;

  final status = unit.filingStatus;

  // Student loan interest: capped, then phased out, and denied outright to
  // separate filers.
  final slPhaseOut = taxYear.studentLoanInterestPhaseOut[status];
  final slFraction = slPhaseOut == null ? 1.0 : slPhaseOut.fractionAt(preDeductionMagi);
  final deductibleStudentLoanInterest =
      status == FilingStatus.marriedFilingSeparately
          ? Money.zero
          : minMoney(inputs.studentLoanInterestPaid,
                  threshold(taxYear.studentLoanInterestCap)) *
              (1 - slFraction);

  // Traditional IRA deductibility is decided one year at a time: the flag is
  // intent, and this is whether statute allows it (§4.3.1).
  final anyCovered = people.any((p) => _coveredByWorkplacePlan(
      p, household, year, currentYear, inputs.resolvedContributions));
  final iraKey = anyCovered ? 'covered' : 'spouseCoveredOnly';
  final iraPhaseOut = taxYear.iraDeductibilityPhaseOut[status]?[iraKey];
  final deductibleIraPortion = !anyCovered
      ? 1.0
      : 1.0 - (iraPhaseOut?.fractionAt(preDeductionMagi) ?? 0.0);

  final iraPreTax = sumMoney(unitAccounts
          .where((a) =>
              a.contribution.reducesFederalTaxableIncome &&
              a.kind == AccountKind.traditionalIra)
          .map(contributionOf)) *
      deductibleIraPortion;

  final nonSSIncome = incomeBeforeDeductions -
      nonIraPreTax -
      iraPreTax -
      payrollDeductions -
      deductibleStudentLoanInterest;

  // --- how much of the benefit is taxable ---------------------------------
  final fractions = taxYear.socialSecurityTaxableFractions;
  final provisionalIncome = nonSSIncome + ssBenefits * fractions.half;
  final band = taxYear.socialSecurityTaxabilityThresholds[status]!;
  final Money taxableSS;
  if (provisionalIncome <= band.lower) {
    taxableSS = Money.zero;
  } else if (provisionalIncome <= band.upper) {
    taxableSS = minMoney(ssBenefits * fractions.half,
        (provisionalIncome - band.lower) * fractions.half);
  } else {
    taxableSS = minMoney(
      ssBenefits * fractions.cap,
      (provisionalIncome - band.upper) * fractions.cap +
          minMoney(ssBenefits * fractions.half,
              (band.upper - band.lower) * fractions.half),
    );
  }

  // --- §4.3.2 --------------------------------------------------------------
  final federalAgi = nonSSIncome + taxableSS;

  final over65 = people.where((p) => p.ageIn(year) >= 65).length;
  final age65Additional =
      threshold(taxYear.additionalStandardDeductionAge65[status]!) * over65;
  final standard = threshold(taxYear.standardDeduction[status]!);
  final deduction = maxMoney(
      standard + age65Additional, unit.itemizedDeductionTotal ?? Money.zero);

  // The 2025 act's senior deduction sits outside that choice: it is allowed
  // whether the unit itemizes or not, and it lapses after its final year.
  final senior = taxYear.seniorDeduction;
  final qualifyingSeniors = senior == null
      ? 0
      : people.where((p) => p.ageIn(year) >= senior.minAge).length;
  final seniorDeduction = senior == null || year > senior.throughYear
      ? Money.zero
      : threshold(senior.amountPerPerson) *
          (1 - senior.phaseOut[status]!.fractionAt(federalAgi)) *
          qualifyingSeniors;

  final taxableBeforeQbi =
      (federalAgi - deduction - seniorDeduction).orZeroIfNegative;

  // §199A: pass-through business income, rental net of depreciation, less the
  // SE deduction and the pre-tax contributions funded from those streams.
  final qbiStreams = household.incomeStreams.where((s) =>
      personIds.contains(s.personId) && s.isQualifiedBusinessIncome);
  final qbiGross = sumMoney(qbiStreams.map((s) => s.kind == IncomeKind.rentalNet
      ? taxableRental
      : s.resolvedAmount(year, currentYear: currentYear)));
  final qbi = qbiGross - seDeduction;

  final netCapitalGain = realizedLongTermGains + qualifiedDividends;
  final qbiDeduction = minMoney(
    qbi.orZeroIfNegative * taxYear.qbiDeductionRate,
    (taxableBeforeQbi - netCapitalGain).orZeroIfNegative *
        taxYear.qbiDeductionRate,
  );

  return TaxableIncome(
    ssBenefits: ssBenefits,
    rentalIncome: rentalIncome,
    taxableRental: taxableRental,
    pensionIncome: pensionIncome,
    otherStreamIncome: otherStreamIncome,
    rmdIncome: inputs.rmdIncome,
    inAccountInvestmentIncome: inAccountInvestmentIncome,
    qualifiedDividends: qualifiedDividends,
    ordinaryInAccountIncome: ordinaryInAccountIncome,
    realizedLongTermGains: realizedLongTermGains,
    realizedShortTermGains: realizedShortTermGains,
    deductibleStudentLoanInterest: deductibleStudentLoanInterest,
    preDeductionMagi: preDeductionMagi,
    deductibleIraPortion: deductibleIraPortion,
    nonSSIncome: nonSSIncome,
    provisionalIncome: provisionalIncome,
    taxableSS: taxableSS,
    federalAgi: federalAgi,
    deduction: deduction,
    seniorDeduction: seniorDeduction,
    taxableBeforeQbi: taxableBeforeQbi,
    qbi: qbi,
    qbiDeduction: qbiDeduction,
    fedTaxable: (taxableBeforeQbi - qbiDeduction).orZeroIfNegative,
  );
}

/// Whether an unattributed entity reaches this unit: null resolves to the
/// household's only tax unit, which exists only while there is one
/// (invariant 24).
bool _reachesUnit(Id? personId, TaxUnit unit, Household household) {
  if (personId == null) return household.soleTaxUnit?.id == unit.id;
  return household.personById(personId)?.taxUnitId == unit.id;
}

/// Whether a person is covered by a workplace plan this year (§4.3.1): they
/// hold an account in a workplace family that is receiving something.
bool _coveredByWorkplacePlan(
  Person person,
  Household household,
  int year,
  int currentYear,
  Map<Id, Money> resolved,
) =>
    household.accountsFor(person.id).any((a) {
      const workplace = {
        LimitFamily.electiveDeferral,
        LimitFamily.simpleDeferral,
        LimitFamily.sep,
      };
      if (!workplace.contains(a.limitFamily)) return false;
      final amount = resolved[a.id] ??
          resolveCommittedContribution(a, household, year, currentYear);
      return amount.isPositive || a.contribution.employerMatch != null;
    });

/// What an account's committed contribution asks for before any cap (§3.4.1).
Money resolveCommittedContribution(
  Account account,
  Household household,
  int year,
  int currentYear,
) {
  final c = account.contribution;
  if (c.mode == ContributionMode.fixedAmount) {
    return c.uncappedAmount(year, base: Money.zero);
  }
  final base = sumMoney(c.contributionBaseStreamIds
      .map((id) => household.incomeStreams.where((s) => s.id == id).firstOrNull)
      .whereType<IncomeStream>()
      .map((s) => s.resolvedAmount(year, currentYear: currentYear)));
  return c.uncappedAmount(year, base: base);
}
