import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

AccountState taxableWith({num balance = 100000, num basis = 60000}) =>
    AccountState(brokerageIn(balance: balance, basis: basis));

AccountState rothWith({num balance = 100000, num basis = 40000}) =>
    AccountState(Account(
      id: 'roth',
      personId: 'p1',
      label: 'Roth IRA',
      kind: AccountKind.rothIra,
      taxTreatment: TaxTreatment.roth,
      limitFamily: LimitFamily.ira,
      balance: Money.dollars(balance),
      rothContributionBasis: Money.dollars(basis),
      isRestrictedPurpose: false,
      assetAllocationId: 'stocks',
      contribution:
          const Contribution(mode: ContributionMode.fixedAmount, value: 0),
    ));

void main() {
  group('§6.3 the basis denominator', () {
    test('a draw takes basis at the ratio it actually saw', () {
      // The rule this whole test file exists for. $40,000 out of $100,000 is
      // 40% of the basis. A $60,000 closing balance would imply 67%, and that
      // was the defect the domain review found.
      final a = taxableWith(balance: 100000, basis: 60000);
      a.withdraw(Money.dollars(40000));

      expect(a.balance, Money.dollars(60000));
      expect(a.costBasis, Money.dollars(36000),
          reason: '60,000 less 40% of it');
      expect(a.costBasis, isNot(Money.dollars(20000)),
          reason: '20,000 is what the closing-balance denominator gives');
    });

    test('the basis fraction is unchanged by a withdrawal', () {
      // Pro rata means the account stays the same shape: 60% basis before,
      // 60% basis after.
      final a = taxableWith(balance: 100000, basis: 60000);
      final before = a.costBasis.ratioTo(a.balance);
      a.withdraw(Money.dollars(40000));
      expect(a.costBasis.ratioTo(a.balance), closeTo(before, 1e-9));
    });

    test('draining the account takes all the basis with it', () {
      final a = taxableWith(balance: 100000, basis: 60000);
      a.withdraw(Money.dollars(100000));
      expect(a.balance, Money.zero);
      expect(a.costBasis, Money.zero);
    });

    test('a draw larger than the balance takes only what is there', () {
      final a = taxableWith(balance: 100000, basis: 60000);
      expect(a.withdraw(Money.dollars(250000)), Money.dollars(100000));
      expect(a.balance, Money.zero);
    });

    test('a taxable draw yields basis and gain together (§8.4.1)', () {
      // $40,000 against an account that is 70% basis produces $28,000 of
      // untaxed return of capital and $12,000 of long-term gain.
      final a = taxableWith(balance: 100000, basis: 70000);
      expect(a.gainPortionOf(Money.dollars(40000)), Money.dollars(12000));
    });
  });

  group('§6.3 what raises basis', () {
    test('after-tax dollars bring their basis with them', () {
      final a = taxableWith(balance: 100000, basis: 60000);
      a.deposit(Money.dollars(10000));
      expect(a.costBasis, Money.dollars(70000));
    });

    test('an inheritance deposited without basis reads as gain later', () {
      final a = taxableWith(balance: 100000, basis: 60000);
      a.deposit(Money.dollars(10000), afterTax: false);
      expect(a.costBasis, Money.dollars(60000));
    });

    test('reinvested distributions raise basis without moving the balance', () {
      // They are taxed this year; without this step the same dollars would be
      // taxed again as gains on the way out.
      final a = taxableWith(balance: 100000, basis: 60000);
      a.creditInvestmentIncome(Money.dollars(1300));
      expect(a.costBasis, Money.dollars(61300));
      expect(a.balance, Money.dollars(100000));
    });

    test('realising a gain raises basis by the same amount', () {
      // Otherwise capitalGainsRealizationRate re-realises the same gains
      // forever.
      final a = taxableWith(balance: 100000, basis: 60000);
      final gain = a.realizeGains(0.05);
      expect(gain, Money.dollars(2000), reason: '5% of the 40,000 unrealised');
      expect(a.costBasis, Money.dollars(62000));
      expect(a.unrealizedGain, Money.dollars(38000));
    });

    test('realisation never manufactures a loss', () {
      final a = taxableWith(balance: 50000, basis: 80000);
      expect(a.realizeGains(0.05), Money.zero);
      expect(a.costBasis, Money.dollars(80000));
    });

    test('a tax-deferred account tracks no basis at all', () {
      final a = AccountState(traditional401k(balance: 200000));
      a.deposit(Money.dollars(20000));
      a.withdraw(Money.dollars(50000));
      expect(a.costBasis, Money.zero);
    });
  });

  group('§6.3 Roth contribution basis', () {
    test('employee contributions raise it, employer match does not', () {
      final a = rothWith(balance: 100000, basis: 40000);
      a.contribute(Money.dollars(7000));
      a.creditEmployerMatch(Money.dollars(3000));
      expect(a.rothContributionBasis, Money.dollars(47000));
      expect(a.balance, Money.dollars(110000));
    });

    test('a basis draw reduces it one for one, not pro rata', () {
      // Roth IRA distributions come out contributions first, which is what
      // makes them the backbone of a bridge (§8.4.1).
      final a = rothWith(balance: 100000, basis: 40000);
      a.withdraw(Money.dollars(10000), fromRothBasis: true);
      expect(a.rothContributionBasis, Money.dollars(30000));
    });

    test('an earnings draw leaves contribution basis alone', () {
      final a = rothWith(balance: 100000, basis: 40000);
      a.withdraw(Money.dollars(10000));
      expect(a.rothContributionBasis, Money.dollars(40000));
    });

    test('basis never goes below zero', () {
      final a = rothWith(balance: 100000, basis: 40000);
      a.withdraw(Money.dollars(60000), fromRothBasis: true);
      expect(a.rothContributionBasis, Money.zero);
    });
  });

  group('§6.2 the mid-year convention', () {
    test('flows earn half a year and the opening balance earns all of it', () {
      final a = taxableWith(balance: 100000, basis: 100000);
      a.contribute(Money.dollars(12000));
      a.grow(assetClasses: assetClasses(), band: BandName.expected, frac: 1.0);

      // stocks: 5% expected real return. The opening balance compounds for the
      // whole year, the contribution for half of it.
      const januaryFirst = 100000 * 1.05 + 12000 * 1.05;
      expect(a.balance.dollars,
          closeTo(100000 * 1.05 + 12000 * 1.0246950766, 1.0));
      expect(a.balance.dollars, lessThan(januaryFirst),
          reason: 'a full year on the contribution would be more');
    });

    test('a January-one convention would overstate each contribution', () {
      final half = taxableWith(balance: 0, basis: 0);
      half.contribute(Money.dollars(10000));
      half.grow(assetClasses: assetClasses(), band: BandName.expected, frac: 1.0);

      expect(half.balance.dollars, closeTo(10000 * 1.024695, 0.5));
      expect(half.balance < Money.dollars(10500), isTrue,
          reason: 'about 2.5% less than a full year of compounding');
    });

    test('a partial first year grows for its fraction only', () {
      final a = taxableWith(balance: 100000, basis: 100000);
      a.grow(assetClasses: assetClasses(), band: BandName.expected, frac: 0.5);
      expect(a.balance.dollars, closeTo(100000 * 1.0246950766, 0.5));
    });

    test('the pessimistic band can lose money and never goes negative', () {
      final a = AccountState(Account(
        id: 'cash',
        personId: 'p1',
        label: 'Cash',
        kind: AccountKind.cashSavings,
        taxTreatment: TaxTreatment.taxable,
        limitFamily: LimitFamily.none,
        balance: Money.dollars(10000),
        costBasis: Money.dollars(10000),
        isRestrictedPurpose: false,
        assetAllocationId: 'cash',
        contribution:
            const Contribution(mode: ContributionMode.fixedAmount, value: 0),
      ));
      a.grow(
          assetClasses: assetClasses(),
          band: BandName.pessimistic,
          frac: 1.0);
      expect(a.balance < Money.dollars(10000), isTrue);
      expect(a.balance.isNegative, isFalse);
    });
  });
}
