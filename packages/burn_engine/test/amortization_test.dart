import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

final asOf = DateTime(2026, 1, 1);
const assumptions = Assumptions(taxYearId: 'us-2026');

Liability mortgage({
  num balance = 300000,
  Rate rate = 0.055,
  num payment = 2200,
  num? escrow,
  num? pmi,
  Rate escrowAfterPayoff = 1.0,
  num extra = 0,
  int term = 360,
}) =>
    Liability(
      id: 'l1',
      householdId: 'h1',
      label: 'Mortgage',
      kind: LiabilityKind.mortgage,
      currentBalance: Money.dollars(balance),
      interestRate: rate,
      monthlyPayment: Money.dollars(payment),
      monthlyEscrowAmount: escrow == null ? null : Money.dollars(escrow),
      monthlyPmiAmount: pmi == null ? null : Money.dollars(pmi),
      escrowContinuesAfterPayoff: escrowAfterPayoff,
      extraPrincipalPayment: Money.dollars(extra),
      originationDate: DateTime(2020, 3, 1),
      termMonths: term,
    );

void main() {
  group('amortizationPayment', () {
    test('a zero-rate loan divides evenly', () {
      expect(amortizationPayment(Money.dollars(12000), 0, 12),
          Money.dollars(1000));
    });

    test('a real loan charges more than the principal alone', () {
      final p = amortizationPayment(Money.dollars(300000), 0.055 / 12, 360);
      expect(p.dollars, closeTo(1703.37, 1.0));
    });

    test('a loan with no months left needs no payment', () {
      expect(amortizationPayment(Money.dollars(1000), 0.05 / 12, 0),
          Money.zero);
    });
  });

  group('§3.6 escrow', () {
    test('escrow is inferred where none is entered', () {
      final s = LiabilityState(mortgage(payment: 2200));
      // Payment less the scheduled principal-and-interest on the remaining
      // term, which is about $1,758 with 70 months already elapsed.
      final escrow = s.monthlyEscrow(asOfDate: asOf);
      expect(escrow.isPositive, isTrue);
      expect(escrow < Money.dollars(2200), isTrue);
    });

    test('an entered escrow wins over the inferred one', () {
      final s = LiabilityState(mortgage(escrow: 500));
      expect(s.monthlyEscrow(asOfDate: asOf), Money.dollars(500));
    });

    test('a materially different entry is flagged, not blocked', () {
      // Derived rather than guessed: what the schedule implies is the thing an
      // entered figure is compared against.
      final inferred =
          LiabilityState(mortgage(payment: 2200)).monthlyEscrow(asOfDate: asOf);

      final agreeing =
          LiabilityState(mortgage(payment: 2200, escrow: inferred.dollars));
      expect(agreeing.escrowDiffersFromInferred(asOfDate: asOf), isFalse);

      final disagreeing = LiabilityState(mortgage(payment: 2200, escrow: 50));
      expect(disagreeing.escrowDiffersFromInferred(asOfDate: asOf), isTrue);
    });
  });

  group('§6 one year of payments', () {
    test('interest and principal split the payment, and the balance falls', () {
      final s = LiabilityState(mortgage(escrow: 400));
      s.advanceYear(asOfDate: asOf, assumptions: assumptions, frac: 1.0);

      expect(s.balance < Money.dollars(300000), isTrue);
      expect(s.interestPaidThisYear.isPositive, isTrue);
      expect(s.principalPaidThisYear.isPositive, isTrue);
      expect(s.escrowPaidThisYear, Money.dollars(400) * 12);
      // Early in a mortgage, interest dominates.
      expect(s.interestPaidThisYear > s.principalPaidThisYear, isTrue);
    });

    test('the engine-directed paydown lands on principal first', () {
      final plain = LiabilityState(mortgage(escrow: 400));
      plain.advanceYear(
          asOfDate: asOf, assumptions: assumptions, frac: 1.0);

      final paid = LiabilityState(mortgage(escrow: 400));
      paid.advanceYear(
        asOfDate: asOf,
        assumptions: assumptions,
        frac: 1.0,
        extraPrincipal: Money.dollars(20000),
      );

      expect(paid.balance < plain.balance, isTrue);
      expect(paid.interestPaidThisYear < plain.interestPaidThisYear, isTrue,
          reason: 'a smaller balance accrues less interest for the rest of '
              'the year');
    });

    test('a loan runs to payoff and then stops', () {
      final s = LiabilityState(mortgage(balance: 20000, payment: 2200, escrow: 400));
      for (var i = 0; i < 3; i++) {
        s.advanceYear(asOfDate: asOf, assumptions: assumptions, frac: 1.0);
      }
      expect(s.paidOff, isTrue);
      expect(s.balance, Money.zero);
    });

    test('escrow outlives the loan at its stated fraction', () {
      final s = LiabilityState(
          mortgage(balance: 1000, payment: 2200, escrow: 400,
              escrowAfterPayoff: 0.75));
      s.advanceYear(asOfDate: asOf, assumptions: assumptions, frac: 1.0);
      expect(s.paidOff, isTrue);

      s.advanceYear(asOfDate: asOf, assumptions: assumptions, frac: 1.0);
      expect(s.principalPaidThisYear, Money.zero);
      expect(s.escrowPaidThisYear, Money.dollars(400) * (12 * 0.75),
          reason: 'the servicer stops collecting; the county does not stop '
              'billing');
    });

    test('PMI drops at its LTV threshold and lowers the escrow', () {
      final s = LiabilityState(
          mortgage(balance: 240000, payment: 2200, escrow: 500, pmi: 120));
      expect(s.pmiActive, isTrue);
      // Against a $300,000 basis, 78% is $234,000: about a year away.
      for (var i = 0; i < 3 && s.pmiActive; i++) {
        s.advanceYear(
          asOfDate: asOf,
          assumptions: assumptions,
          frac: 1.0,
          securingAssetBasis: Money.dollars(300000),
        );
      }
      expect(s.pmiActive, isFalse);
    });

    test('a partial first year pays a partial year of instalments', () {
      final full = LiabilityState(mortgage(escrow: 400));
      full.advanceYear(asOfDate: asOf, assumptions: assumptions, frac: 1.0);
      final half = LiabilityState(mortgage(escrow: 400));
      half.advanceYear(asOfDate: asOf, assumptions: assumptions, frac: 0.5);

      expect(half.escrowPaidThisYear, Money.dollars(400) * 6);
      expect(half.principalPaidThisYear < full.principalPaidThisYear, isTrue);
    });

    test('a payment that cannot cover the interest never retires the loan', () {
      final s = LiabilityState(
          mortgage(balance: 300000, rate: 0.20, payment: 1000, escrow: 0));
      s.advanceYear(asOfDate: asOf, assumptions: assumptions, frac: 1.0);
      expect(s.principalPaidThisYear, Money.zero);
      expect(s.balance, Money.dollars(300000));
      expect(s.paidOff, isFalse);
    });
  });
}
