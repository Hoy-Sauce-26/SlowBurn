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

  group('lookups that run past their last row (§3.12)', () {
    test('the RMD table saturates rather than running off the end', () {
      expect(ty.rmdDivisorFor(90), 12.2);
      expect(ty.rmdDivisorFor(130), ty.rmdDivisorFor(120),
          reason: 'past 120 the last published row stands');
    });

    test('the poverty level extends by its own published increment', () {
      final eight = ty.povertyLevel('US', 8);
      final ten = ty.povertyLevel('US', 10);
      expect(ten - eight, ty.federalPovertyLevelIncrement * 2);
    });

    test('Alaska and Hawaii carry their own higher figures', () {
      expect(ty.povertyLevel('AK', 1) > ty.povertyLevel('US', 1), isTrue);
      expect(ty.povertyLevel('HI', 1) > ty.povertyLevel('US', 1), isTrue);
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
