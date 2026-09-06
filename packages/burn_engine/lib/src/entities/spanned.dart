/// The span shape shared by `IncomeStream`, `Contribution`, `ExpenseItem` and
/// `PayrollDeduction`, and §3.3's proration rule written once.
library;

mixin Spanned {
  int? get startYear;
  int? get endYear;

  /// 1–12, null meaning January.
  int? get startMonth;

  /// 1–12, null meaning December.
  int? get endMonth;

  bool activeIn(int year) =>
      (startYear == null || year >= startYear!) &&
      (endYear == null || year <= endYear!);

  /// The share of [year] this span covers, §3.3.
  ///
  /// Only the span's own first and last year are ever partial. A span whose
  /// start and end fall in the same year is trimmed at both ends by the same
  /// expression, which is why the two subtractions are not exclusive.
  double activeFraction(int year) {
    if (!activeIn(year)) return 0;
    var fraction = 1.0;
    if (startYear != null && year == startYear && startMonth != null) {
      fraction -= (startMonth! - 1) / 12;
    }
    if (endYear != null && year == endYear && endMonth != null) {
      fraction -= (12 - endMonth!) / 12;
    }
    return fraction < 0 ? 0 : fraction;
  }
}
