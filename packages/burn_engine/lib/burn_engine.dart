/// The Slow Burn projection engine.
///
/// Pure Dart by design: `docs/domain.md` resolves a fixed point (§4.3 ⇄ §4.4)
/// and forks a full projection per candidate retirement year (§8.2), and none
/// of that should need a widget harness to test.
library;

export 'src/enums.dart';
export 'src/types.dart';
export 'src/entities/account.dart';
export 'src/entities/assumptions.dart';
export 'src/entities/derivations.dart';
export 'src/entities/events.dart';
export 'src/entities/expenses.dart';
export 'src/entities/household.dart';
export 'src/entities/income.dart';
export 'src/entities/payroll.dart';
export 'src/entities/person.dart';
export 'src/entities/property.dart';
export 'src/entities/spanned.dart';
export 'src/taxyear/tax_year.dart';
