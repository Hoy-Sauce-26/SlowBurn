import 'dart:io';
import 'dart:math' as math;

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

void main() {
  final source =
      File('../../assets/tax_years/2026.json').readAsStringSync();
  final ty = parseTaxYear(source);

  group('the bundled 2026 ruleset', () {
    test('round-trips through the loader', () {
      expect(ty.id, 'us-2026');
      expect(ty.year, 2026);
      expect(ty.federalBrackets[FilingStatus.single], isNotEmpty);
      expect(ty.stateRules['PA'], isNotNull);
    });

    test('carries the statutory rates §3.12 names', () {
      expect(ty.oasdiRate, 0.062);
      expect(ty.medicareRate, 0.0145);
      expect(ty.niitRate, 0.038);
      expect(ty.qbiDeductionRate, 0.20);
      expect(ty.earlyWithdrawalPenaltyRate, 0.10);
      expect(ty.hsaNonMedicalPenaltyRate, 0.20);
      expect(ty.unrecapturedSection1250Rate, 0.25);
      expect(ty.residentialDepreciationYears, 27.5);
      expect(ty.childTaxCreditQualifyingAge, 17);
    });

    test('derives the self-employment rates as twice the employee rates', () {
      // §4.2: derived rather than stored, so the two cannot drift apart across
      // a tax-year update.
      expect(ty.seOasdiRate, closeTo(0.124, 1e-12));
      expect(ty.seMedicareRate, closeTo(0.029, 1e-12));
    });

    test('marks the never-restated thresholds as fixed', () {
      // §7.4: a fixed threshold must be deflated each projected year, or an
      // increasing share of households silently stops crossing it.
      expect(ty.niitThreshold[FilingStatus.single]!.indexed, isFalse);
      expect(ty.section121Exclusion[FilingStatus.marriedFilingJointly]!.indexed,
          isFalse);
      expect(ty.standardDeduction[FilingStatus.single]!.indexed, isTrue);
    });

    test('a fixed threshold deflates and an indexed one does not', () {
      final niit = ty.niitThreshold[FilingStatus.single]!;
      final real =
          niit.realValueIn(2036, currentYear: 2026, inflation: 0.025);
      expect(real < niit.value, isTrue);
      expect(real.dollars, closeTo(200000 / math.pow(1.025, 10), 1),
          reason: 'ten years of 2.5% deflation off a fixed \$200,000');

      final std = ty.standardDeduction[FilingStatus.single]!;
      expect(std.realValueIn(2036, currentYear: 2026, inflation: 0.025),
          std.value);
    });
  });

  group('the 2026 federal figures', () {
    test('carry the published amounts, not last year\'s', () {
      expect(ty.standardDeduction[FilingStatus.single]!.value,
          Money.dollars(16100));
      expect(ty.standardDeduction[FilingStatus.marriedFilingJointly]!.value,
          Money.dollars(32200));
      expect(ty.federalBrackets[FilingStatus.single]!.first.upTo,
          Money.dollars(12400));
      expect(ty.federalBrackets[FilingStatus.marriedFilingJointly]![5].upTo,
          Money.dollars(768700));
      expect(ty.socialSecurityWageBase, Money.dollars(184500));
      expect(ty.contributionLimits[LimitFamily.electiveDeferral]!.annual,
          Money.dollars(24500));
      expect(ty.annualAdditions415c, Money.dollars(72000));
      expect(ty.federalPovertyLevel['US']![1], Money.dollars(15960));
    });

    test('give a married couple the smaller age-65 addition each', () {
      // §63(f) is $2,050 a head for someone unmarried and $1,650 otherwise,
      // and the pipeline adds one per person over 65.
      expect(ty.additionalStandardDeductionAge65[FilingStatus.single]!.value,
          Money.dollars(2050));
      expect(
          ty.additionalStandardDeductionAge65[
                  FilingStatus.marriedFilingJointly]!
              .value,
          Money.dollars(1650));
    });

    test('put the premium tax credit back on its pre-2021 schedule', () {
      // The enhanced credits expired with 2025: contributions rise at every
      // income and the 400% cliff returns.
      expect(ty.acaMaximumFplPercent, 400,
          reason: 'above four times the poverty line the credit is gone');
      expect(ty.acaApplicablePercentageTable.first.applicablePercent, 0.0210,
          reason: 'the poorest household now contributes something');
      expect(ty.acaApplicablePercentageTable.last.applicablePercent, 0.0996);
    });
  });

  group('the state layer', () {
    test('covers every state and DC, so no household is unpriced', () {
      expect(ty.stateRules, hasLength(51));
      expect(ty.stateRules.containsKey('DC'), isTrue);
      expect(ty.stateRules.containsKey('PR'), isFalse);
    });

    test('the nine states with no income tax charge nothing', () {
      for (final code in ['AK', 'FL', 'NV', 'NH', 'SD', 'TN', 'TX', 'WY', 'WA']) {
        expect(ty.stateRules[code]!.leviesNoIncomeTax, isTrue,
            reason: '$code levies no broad income tax');
      }
    });

    test('every schedule rises, and every bracket is a real rate', () {
      for (final rules in ty.stateRules.values) {
        for (final status in FilingStatus.values) {
          final brackets = rules.bracketsFor(status);
          Money? previous;
          for (final b in brackets) {
            expect(b.rate, inInclusiveRange(0, 0.15),
                reason: '${rules.code} has a rate outside anything a state '
                    'charges');
            if (b.upTo != null && previous != null) {
              expect(b.upTo!.cents, greaterThan(previous.cents),
                  reason: '${rules.code} has a bracket that does not rise');
            }
            if (b.upTo != null) previous = b.upTo;
          }
          if (brackets.isNotEmpty) {
            expect(brackets.last.upTo, isNull,
                reason: '${rules.code} leaves its top bracket bounded, so the '
                    'highest earners fall off the end of it');
          }
        }
      }
    });

    test('a married couple is not taxed on a single filer schedule', () {
      // The whole point of splitting the schedules: California's 9.3% starts
      // at twice the income for a couple, and getting that wrong overstates
      // state tax for most households in the app.
      final ca = ty.stateRules['CA']!;
      final single = ca.bracketsFor(FilingStatus.single);
      final joint = ca.bracketsFor(FilingStatus.marriedFilingJointly);
      expect(joint[1].upTo!.cents, greaterThan(single[1].upTo!.cents));
      expect(ca.standardDeductionFor(FilingStatus.marriedFilingJointly).cents,
          ca.standardDeductionFor(FilingStatus.single).cents * 2);
    });

    test('filing separately follows the single schedule', () {
      final ny = ty.stateRules['NY']!;
      expect(ny.bracketsFor(FilingStatus.marriedFilingSeparately),
          ny.bracketsFor(FilingStatus.single));
      expect(ny.bracketsFor(FilingStatus.qualifyingSurvivingSpouse),
          ny.bracketsFor(FilingStatus.marriedFilingJointly));
    });

    test('a state that exempts its first dollars starts at zero', () {
      // Mississippi charges nothing below $10,000 and 4% above it, and a
      // flat 4% would tax income the state does not reach.
      final ms = ty.stateRules['MS']!.bracketsFor(FilingStatus.single);
      expect(ms.first.rate, 0);
      expect(ms.first.upTo, Money.dollars(10000));
      expect(ms.last.rate, 0.04);
    });
  });

  group('lookups that run past their last row (§3.12)', () {
    test('the RMD table saturates rather than running off the end', () {
      expect(ty.rmdDivisorFor(90), 12.2);
      expect(ty.rmdDivisorFor(130), ty.rmdDivisorFor(120),
          reason: 'past 120 the last published row stands');
    });

    test('the poverty level extends by its own published increment', () {
      final eight = ty.povertyLevel('US', 8);
      final ten = ty.povertyLevel('US', 10);
      expect(ten - eight, ty.federalPovertyLevelIncrement['US']! * 2);
    });

    test('Alaska and Hawaii carry their own higher figures', () {
      expect(ty.povertyLevel('AK', 1) > ty.povertyLevel('US', 1), isTrue);
      expect(ty.povertyLevel('HI', 1) > ty.povertyLevel('US', 1), isTrue);
    });

    test('and extend by their own increment past the published table', () {
      // Alaska adds $7,100 a head where the mainland adds $5,680, so a large
      // household there was being shown too low a poverty line.
      expect(ty.povertyLevel('AK', 10) - ty.povertyLevel('AK', 8),
          ty.federalPovertyLevelIncrement['AK']! * 2);
      expect(ty.federalPovertyLevelIncrement['AK']! >
          ty.federalPovertyLevelIncrement['US']!, isTrue);
    });
  });

  group('catch-up tiers (§3.4.2)', () {
    test('the tier whose span contains the age wins, and 64 steps back down',
        () {
      final deferral = ty.contributionLimits[LimitFamily.electiveDeferral]!;
      expect(deferral.catchUpFor(45), Money.zero);
      expect(deferral.catchUpFor(55).dollars, 8000);
      expect(deferral.catchUpFor(61).dollars, 11250,
          reason: 'SECURE 2.0 raises the catch-up for 60 through 63');
      expect(deferral.catchUpFor(64).dollars, 8000,
          reason: 'and it drops back at 64');
    });

    test('education and none are uncapped, carrying no annual limit', () {
      expect(ty.contributionLimits[LimitFamily.education]!.annual, isNull);
      expect(ty.contributionLimits[LimitFamily.none]!.annual, isNull);
    });
  });

  group('the loader refuses what it cannot trust', () {
    test('money must be integer cents (invariant 10)', () {
      expect(
        () => parseTaxYear('{"id":"x","year":2026,'
            '"socialSecurityWageBase":184500.55}'),
        throwsA(isA<TaxYearFormatException>()),
      );
    });

    test('a missing key names itself', () {
      expect(
        () => parseTaxYear('{"id":"x","year":2026}'),
        throwsA(predicate(
            (e) => e is TaxYearFormatException && e.message.contains('missing'))),
      );
    });
  });
}
