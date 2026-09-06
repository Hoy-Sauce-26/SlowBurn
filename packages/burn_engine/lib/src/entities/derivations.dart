/// The two axes an `Account`'s `kind` decides, and the one it does not.
///
/// §3.4 stores `taxTreatment` and `limitFamily` alongside `kind` rather than
/// deriving them at read time, so a custom account can set them. These are the
/// defaults a new account starts from, and invariant 29 is what stops the
/// stored pair from becoming nonsense.
library;

import '../enums.dart';

TaxTreatment defaultTaxTreatment(AccountKind kind) => switch (kind) {
      AccountKind.traditional401k ||
      AccountKind.traditional403b ||
      AccountKind.traditionalTsp ||
      AccountKind.traditionalIra ||
      AccountKind.sepIra ||
      AccountKind.simpleIra =>
        TaxTreatment.taxDeferred,
      AccountKind.roth401k ||
      AccountKind.roth403b ||
      AccountKind.rothTsp ||
      AccountKind.rothIra =>
        TaxTreatment.roth,
      AccountKind.hsa => TaxTreatment.hsaTriple,
      AccountKind.education529 => TaxTreatment.educationTaxFree,
      AccountKind.taxableBrokerage ||
      AccountKind.cashSavings ||
      AccountKind.cashChecking =>
        TaxTreatment.taxable,
    };

/// §3.4.2's table, which is what bounds a contribution.
LimitFamily defaultLimitFamily(AccountKind kind) => switch (kind) {
      AccountKind.traditional401k ||
      AccountKind.roth401k ||
      AccountKind.traditional403b ||
      AccountKind.roth403b ||
      AccountKind.traditionalTsp ||
      AccountKind.rothTsp =>
        LimitFamily.electiveDeferral,
      AccountKind.simpleIra => LimitFamily.simpleDeferral,
      AccountKind.traditionalIra || AccountKind.rothIra => LimitFamily.ira,
      AccountKind.sepIra => LimitFamily.sep,
      AccountKind.hsa => LimitFamily.hsa,
      AccountKind.education529 => LimitFamily.education,
      AccountKind.taxableBrokerage ||
      AccountKind.cashSavings ||
      AccountKind.cashChecking =>
        LimitFamily.none,
    };

/// Whether an account is spendable on one purpose only, and so counts in
/// `netWorth` while staying out of `liquidNetWorth` (§3.4).
///
/// Keyed on `taxTreatment` rather than `kind`, that being the axis a custom
/// account may set. Keying it on `kind` would let a custom education account
/// count as liquid with no `WithdrawalSource` able to spend it.
bool isRestrictedPurpose(TaxTreatment treatment) =>
    treatment == TaxTreatment.educationTaxFree;

/// Whether a stream pays FICA, before any per-stream override (§3.3).
///
/// False for `selfEmployment`, which §4.2 handles on its own terms: SE income
/// pays both halves through `seTax` and shares the OASDI cap with wages. A
/// stream counted in both places would be taxed twice.
bool defaultIsFicaSubject(IncomeKind kind) =>
    kind == IncomeKind.w2Wages ||
    kind == IncomeKind.bonus ||
    kind == IncomeKind.rsuVesting;

/// Whether a stream feeds the §199A deduction, before any override (§3.3).
bool defaultIsQualifiedBusinessIncome(IncomeKind kind) =>
    kind == IncomeKind.selfEmployment || kind == IncomeKind.rentalNet;

/// What each of the three `reduces*` flags defaults to for a contribution into
/// an account of this kind (§3.4.3).
///
/// The FICA column is the one that surprises: only cafeteria-plan money under
/// §125 reaches it, so a payroll HSA reduces FICA wages and a 401(k) deferral
/// does not. Whether an HSA contribution is *via payroll* is not a property of
/// the account, so [hsaViaPayroll] is passed in.
({bool federal, bool state, bool fica}) defaultReducesFlags(
  AccountKind kind, {
  bool hsaViaPayroll = true,
}) =>
    switch (kind) {
      AccountKind.traditional401k ||
      AccountKind.traditional403b ||
      AccountKind.traditionalTsp ||
      AccountKind.traditionalIra ||
      AccountKind.sepIra ||
      AccountKind.simpleIra =>
        (federal: true, state: true, fica: false),
      AccountKind.hsa => (
          federal: true,
          state: true,
          fica: hsaViaPayroll,
        ),
      AccountKind.roth401k ||
      AccountKind.roth403b ||
      AccountKind.rothTsp ||
      AccountKind.rothIra ||
      AccountKind.education529 ||
      AccountKind.taxableBrokerage ||
      AccountKind.cashSavings ||
      AccountKind.cashChecking =>
        (federal: false, state: false, fica: false),
    };
