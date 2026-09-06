/// Which screen each flag belongs on.
///
/// A flag in the results panel says the answer has a caveat. A flag on the
/// screen that caused it says what to do about it, and those are different
/// jobs. `escrowDiffersFromInferred` is actionable next to the mortgage and
/// merely worrying next to the FIRE number.
library;

enum FlagHome { household, income, accounts, spending, debts, plan }

const flagHomes = <String, FlagHome>{
  // Who is in the plan and how they file.
  'filingStatusNoLongerQualifies': FlagHome.household,
  'earningsTestNotModeled': FlagHome.household,

  // What comes in.
  'electionExceededRealizedSurplus': FlagHome.income,
  'qbiLimitNotModeled': FlagHome.income,

  // What is saved, and the rules around it.
  'contributionLimitExceeded': FlagHome.accounts,
  'hsaContributionsStoppedAtMedicare': FlagHome.accounts,
  'rothIraIncomeLimitReached': FlagHome.accounts,
  'unvestedMatchAtRisk': FlagHome.accounts,
  'rothRolloverAssumed': FlagHome.accounts,
  'bufferDepleted': FlagHome.accounts,

  // What goes out.
  'possibleDoubleCount': FlagHome.spending,
  'retirementSpendingNotLevel': FlagHome.spending,

  // What is owed and owned.
  'escrowDiffersFromInferred': FlagHome.debts,
  'payoffLeavesResidualEscrow': FlagHome.debts,
  'derivedPayoffDiffersFromTerm': FlagHome.debts,

  // The answer itself, and the approximations behind it.
  'shortfall': FlagHome.plan,
  'bridgeGapDetected': FlagHome.plan,
  'magiCeilingBreached': FlagHome.plan,
  'acaMagiBelowSubsidyFloor': FlagHome.plan,
  'swrHorizonMismatch': FlagHome.plan,
  'waterfallNotConverged': FlagHome.plan,
};

Set<String> flagsFor(FlagHome home, Set<String> raised) =>
    raised.where((f) => flagHomes[f] == home).toSet();
