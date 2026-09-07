/// Every closed vocabulary in the domain, in the order §3 lists it.
///
/// `529` is `education529` here: Dart identifiers cannot start with a digit,
/// and the wire name is restored by [AccountKind.wireName].
library;

enum ExpenseSharing { pooled, proportional }

enum FilingStatus {
  single,
  marriedFilingJointly,
  marriedFilingSeparately,
  headOfHousehold,
  qualifyingSurvivingSpouse,
}

enum IncomeKind {
  w2Wages,
  selfEmployment,
  bonus,
  rsuVesting,
  rentalNet,
  pension,
  other;

  /// The kinds that stop at retirement and default their `endYear` to the year
  /// before it (§3.3).
  bool get isEarned =>
      this == w2Wages ||
      this == selfEmployment ||
      this == bonus ||
      this == rsuVesting;
}

/// Whether a stream is counted as dependable income (§3.3).
enum IncomeVariability { guaranteed, variable }

enum AccountKind {
  traditional401k,
  roth401k,
  traditional403b,
  roth403b,
  traditionalTsp,
  rothTsp,
  traditionalIra,
  rothIra,
  hsa,
  sepIra,
  simpleIra,
  education529,
  taxableBrokerage,
  cashSavings,
  cashChecking;

  String get wireName => this == education529 ? '529' : name;

  /// Money in a bank rather than an investment. Every dollar of it has already
  /// been taxed, so there is no unrealised gain in it to tax again (§6.3).
  bool get isCash => this == cashSavings || this == cashChecking;
}

enum TaxTreatment { taxDeferred, roth, taxable, hsaTriple, educationTaxFree }

enum LimitFamily {
  electiveDeferral,
  simpleDeferral,
  ira,
  sep,
  hsa,
  education,
  none,
}

enum AllocationMode { singleClass, weighted }

enum ContributionMode { percentOfGross, fixedAmount }

enum MatchFormula { percentOfContribution, percentOfSalary, tiered }

enum PayrollDeductionKind {
  healthPremium,
  dentalVisionPremium,
  healthFsa,
  dependentCareFsa,
  commuterBenefit,
  other;

  /// The kinds whose `endYear` defaults to `employerHealthCoverageEndYear`
  /// rather than to the year before retirement (§3.4.5).
  bool get isCoverageRelated =>
      this == healthPremium || this == dentalVisionPremium;
}

enum AssetCategory {
  primaryResidence,
  investmentProperty,
  vehicle,
  collectible,
  businessEquity,
  other;

  /// Only real property carries `assetSaleCostRate` on sale (§3.5).
  bool get carriesSaleCost =>
      this == primaryResidence || this == investmentProperty;
}

enum LiabilityKind {
  mortgage,
  autoLoan,
  studentLoan,
  creditCard,
  personalLoan,
  heloc,
  other,
}

enum MetaCategory {
  /// Shelter itself: rent, or what is paid to have somewhere to live. The only
  /// category that answers "do you have a roof" (§3.7), which is why the bills
  /// that come with a roof are [housingSupport] and not this. A household
  /// paying an electricity bill for forty years has not thereby housed itself.
  housing,

  /// What a roof costs to keep: utilities, internet, property tax outside
  /// escrow, HOA dues, renter's or contents insurance, upkeep.
  housingSupport,
  transportation,
  food,
  health,
  childcare,
  discretionary,
  insurance,
  education,
  misc,
}

enum ExpenseFrequency {
  monthly,
  quarterly,
  annual;

  /// What one unit of this frequency is worth per year, used to normalise on
  /// save (§3.7).
  int get perYear => switch (this) {
        monthly => 12,
        quarterly => 4,
        annual => 1,
      };
}

enum ExpensePhase { preRetirementOnly, postRetirementOnly, both }

enum OneTimeEventKind {
  inheritance,
  tuition,
  majorRepair,
  vehiclePurchase,
  windfall,
  other,
}

/// How a one-time amount lands in §4.3.1 (§3.8).
enum EventTaxTreatment {
  nonTaxable,
  ordinaryIncome,
  capitalGainShortTerm,
  capitalGainLongTerm,
}

/// `cash` is money that earns nothing, a current account or a drawer. `savings`
/// is money in a bank paying interest, which in real terms is a different
/// holding: the same inflation erodes both, and only one is paid to offset it.
enum AssetClassLabel { usStocks, intlStocks, bonds, reit, savings, cash, crypto }

/// The fixed step vocabulary of the contribution waterfall (§4.4.4), in default
/// order. A scenario reorders or omits, and may not drop [taxableBrokerage]
/// (invariant 29).
enum WaterfallStep {
  matchCapture,
  hsaPayrollToLimit,
  highInterestDebt,
  cashBufferToTarget,
  iraToLimit,
  electiveDeferralToLimit,
  hsaDirectToLimit,
  taxableBrokerage;

  FundingWindow get window => switch (this) {
        matchCapture ||
        hsaPayrollToLimit ||
        electiveDeferralToLimit =>
          FundingWindow.payrollElection,
        iraToLimit || hsaDirectToLimit => FundingWindow.filingDeadline,
        highInterestDebt || cashBufferToTarget || taxableBrokerage =>
          FundingWindow.anytime,
      };

  /// Steps that can fund an account only for a person with earned income that
  /// year (§4.4.2).
  bool get requiresEarnedIncome =>
      this != highInterestDebt &&
      this != cashBufferToTarget &&
      this != taxableBrokerage;
}

/// When in the year a step's destination can accept money (§4.4.2).
enum FundingWindow { payrollElection, anytime, filingDeadline }

/// Ordered draw sources, distinguished by tax character (§8.4.1).
enum WithdrawalSource {
  cash,
  rothIraBasis,
  taxable,
  traditional,
  hsaQualifiedMedical,
  rothEarnings,
  hsaNonMedical,
}

enum SnapshotTrigger { auto, manual }
