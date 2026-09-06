/// Scalar aliases and the small value types that entities are built from.
///
/// `Money` and `Rate` are `double` rather than a wrapper. The domain's own
/// §1.1 rule is that every figure is real dollars in one currency, so there is
/// no unit to confuse and nothing for a wrapper to protect against. `Rate` is
/// always a decimal (0.05, never 5) per invariant 9.
library;

/// Money, in **integer cents** (invariant 10).
///
/// A zero-cost wrapper over `int`, so the invariant is carried by the type
/// rather than by everyone remembering it. Forty years of compounding a balance
/// as a float drifts; rounding to the cent at every store does not.
///
/// Arithmetic that genuinely is fractional — growth, proration, a fixed point —
/// goes through [dollars] and comes back through [Money.dollars]. Rounding is
/// therefore explicit and happens once per store, which is the only place it
/// can be reasoned about.
extension type const Money(int cents) {
  static const zero = Money(0);

  factory Money.dollars(num amount) => Money((amount * 100).round());

  double get dollars => cents / 100;

  bool get isZero => cents == 0;
  bool get isNegative => cents < 0;
  bool get isPositive => cents > 0;

  Money operator +(Money other) => Money(cents + other.cents);
  Money operator -(Money other) => Money(cents - other.cents);
  Money operator -() => Money(-cents);

  /// Scaling by a rate or a fraction. Rounds to the nearest cent.
  Money operator *(num factor) => Money((cents * factor).round());
  Money operator /(num divisor) => Money((cents / divisor).round());

  bool operator <(Money other) => cents < other.cents;
  bool operator <=(Money other) => cents <= other.cents;
  bool operator >(Money other) => cents > other.cents;
  bool operator >=(Money other) => cents >= other.cents;

  /// The ratio of two amounts, which is a rate rather than an amount.
  double ratioTo(Money other) => other.cents == 0 ? 0 : cents / other.cents;

  Money get orZeroIfNegative => cents < 0 ? Money.zero : this;
}

Money minMoney(Money a, Money b) => a.cents <= b.cents ? a : b;
Money maxMoney(Money a, Money b) => a.cents >= b.cents ? a : b;

/// Sums an iterable of amounts. `fold` with [Money.zero] everywhere reads worse
/// than naming the operation once.
Money sumMoney(Iterable<Money> amounts) =>
    amounts.fold(Money.zero, (a, b) => a + b);

typedef Rate = double;
typedef Id = String;

/// A quantity the engine reports once per return band (§8.2).
///
/// Immutable and mapped rather than mutated, so a band's value can never be
/// written back into the wrong slot.
class Band<T> {
  final T pessimistic;
  final T expected;
  final T optimistic;

  const Band({
    required this.pessimistic,
    required this.expected,
    required this.optimistic,
  });

  const Band.same(T value)
      : pessimistic = value,
        expected = value,
        optimistic = value;

  Band<R> map<R>(R Function(T) f) => Band(
        pessimistic: f(pessimistic),
        expected: f(expected),
        optimistic: f(optimistic),
      );

  Iterable<T> get values => [pessimistic, expected, optimistic];

  @override
  String toString() => '($pessimistic / $expected / $optimistic)';
}

/// A result the engine could not produce, as distinct from one it produced as
/// zero (§8.2).
///
/// `notReachable` propagates: anything derived from a retirement year that
/// never arrives is itself unreachable, and the UI names the absence instead of
/// doing arithmetic on it (§10.2).
class NotReachable {
  const NotReachable();
  @override
  String toString() => 'notReachable';
}

const notReachable = NotReachable();

/// Either a value or [notReachable]. `null` means unreachable.
typedef Reachable<T> = T?;

/// A dependent of a `TaxUnit` (§3.2).
class Dependent {
  final DateTime birthDate;
  final bool isStudent;

  /// Defaults to the year the dependent turns 19, or 24 when [isStudent].
  final int? supportEndYear;

  const Dependent({
    required this.birthDate,
    this.isStudent = false,
    this.supportEndYear,
  });

  int get resolvedSupportEndYear =>
      supportEndYear ?? birthDate.year + (isStudent ? 24 : 19);
}

/// One entry in a person's HSA coverage timeline (§3.1).
class HsaCoverageEntry {
  final int fromYear;
  final HsaTier tier;

  const HsaCoverageEntry({required this.fromYear, required this.tier});
}

enum HsaTier { none, self, family }

/// One class in a blended allocation (§3.4).
class AllocationWeight {
  final Id assetClassId;
  final Rate weight;

  const AllocationWeight({required this.assetClassId, required this.weight});
}

/// One tier of a tiered employer match (§3.4.4).
class MatchTier {
  final Rate upToPercentOfSalary;
  final Rate matchRate;

  const MatchTier({
    required this.upToPercentOfSalary,
    required this.matchRate,
  });
}

/// A vesting schedule, surfaced as a warning and reducing no balance (§3.4.4).
sealed class VestingSchedule {
  const VestingSchedule();
}

class ImmediateVesting extends VestingSchedule {
  const ImmediateVesting();
}

class CliffVesting extends VestingSchedule {
  final int years;
  const CliffVesting(this.years);
}

class GradedVesting extends VestingSchedule {
  /// Vested fraction by years of service, ascending.
  final List<({int years, Rate vested})> schedule;
  const GradedVesting(this.schedule);
}
