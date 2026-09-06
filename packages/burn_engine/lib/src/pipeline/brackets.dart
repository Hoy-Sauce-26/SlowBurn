/// Progressive rate schedules, and the stacking the preferential one needs.
library;

import '../taxyear/tax_year.dart';
import '../types.dart';

/// Tax on [amount] under a progressive schedule.
///
/// Each band is charged only on the slice of income inside it, which is what
/// makes the marginal rate differ from the effective one.
Money applyBrackets(Money amount, List<TaxBracket> brackets) {
  if (!amount.isPositive) return Money.zero;
  var tax = Money.zero;
  var floor = Money.zero;
  for (final band in brackets) {
    final ceiling = band.upTo;
    final top = ceiling == null ? amount : minMoney(amount, ceiling);
    final slice = (top - floor).orZeroIfNegative;
    tax += slice * band.rate;
    if (ceiling == null || amount <= ceiling) break;
    floor = ceiling;
  }
  return tax;
}

/// Tax on [amount] under a schedule whose bands are measured from the top of
/// [stackedOn] rather than from zero (§4.3.3).
///
/// Long-term gains sit above ordinary income, so a household with $40,000 of
/// ordinary income and $20,000 of gains pays the 0% rate only on the gains
/// falling below the 0% ceiling *after* the ordinary income has used its share
/// of the room. Charging the gains from zero instead would hand every household
/// a second full 0% band.
Money applyStackedBrackets(
  Money amount, {
  required Money stackedOn,
  required List<TaxBracket> brackets,
}) {
  if (!amount.isPositive) return Money.zero;
  // The tax on the whole stack under this schedule, less what the base alone
  // would have cost, leaves exactly the top slice's tax.
  return applyBrackets(stackedOn + amount, brackets) -
      applyBrackets(stackedOn, brackets);
}
