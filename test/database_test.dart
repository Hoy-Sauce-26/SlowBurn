import 'package:burn_engine/burn_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slow_burn/services/database.dart';

Household household({String id = 'h1', num balance = 250000}) => Household(
      id: id,
      taxUnits: [
        TaxUnit(
          id: 'tu1',
          householdId: id,
          filingStatus: FilingStatus.single,
          stateCode: 'CO',
        ),
      ],
      people: [
        Person(
          id: 'p1',
          displayName: 'Alex',
          birthDate: DateTime(1985, 6, 15),
          taxUnitId: 'tu1',
        ),
      ],
      accounts: [
        Account(
          id: 'k1',
          personId: 'p1',
          label: '401(k)',
          kind: AccountKind.traditional401k,
          taxTreatment: TaxTreatment.taxDeferred,
          limitFamily: LimitFamily.electiveDeferral,
          balance: Money.dollars(balance),
          isRestrictedPurpose: false,
          contribution:
              const Contribution(mode: ContributionMode.fixedAmount, value: 0),
        ),
      ],
    );

Scenario scenario({String id = 'sc1', String householdId = 'h1'}) => Scenario(
      id: id,
      householdId: householdId,
      label: 'Baseline',
      assumptions: const Assumptions(taxYearId: 'us-2026'),
    );

ExportBundle bundle({String householdId = 'h1', num balance = 250000}) =>
    ExportBundle(
      household: household(id: householdId, balance: balance),
      scenarios: [scenario(householdId: householdId)],
      assetClasses: const [
        AssetClass(
          id: 'stocks',
          label: AssetClassLabel.usStocks,
          expectedRealReturn: 0.05,
          pessimisticRealReturn: 0.02,
          optimisticRealReturn: 0.08,
          incomeYield: 0.013,
          qualifiedIncomeFraction: 1.0,
        ),
      ],
    );

ProjectionSnapshot snapshot({
  required String id,
  required DateTime at,
  required String digest,
  String scenarioId = 'sc1',
  SnapshotTrigger trigger = SnapshotTrigger.auto,
  int? expectedYear = 2041,
}) =>
    ProjectionSnapshot(
      id: id,
      scenarioId: scenarioId,
      asOfDate: at,
      trigger: trigger,
      inputDigest: digest,
      taxYearId: 'us-2026',
      retirementYear:
          Band(pessimistic: null, expected: expectedYear, optimistic: 2038),
      fireNumber: Band(
        pessimistic: null,
        expected: Money.dollars(2350000),
        optimistic: Money.dollars(2100000),
      ),
      sustainableLevelSpending: Band(
        pessimistic: null,
        expected: Money.dollars(82000),
        optimistic: Money.dollars(95000),
      ),
      netWorth: Money.dollars(900000),
      liquidNetWorth: Money.dollars(700000),
      investableNetWorth: Money.dollars(650000),
      afterTaxLiquidNetWorth: Money.dollars(600000),
      savingsRate: 0.28,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  setUp(() async => db = await Database.openInMemory());
  tearDown(() async => db.close());

  group('§11 storage round trip', () {
    test('a household survives save and load', () async {
      await db.saveBundle(bundle());
      final loaded = await db.loadBundle('h1');
      expect(loaded, isNotNull);
      // Byte-identical re-export is the real assertion: a dropped field cannot
      // hide behind a spot check.
      expect(exportToJson(loaded!), exportToJson(bundle()));
    });

    test('saving again replaces rather than duplicating', () async {
      await db.saveBundle(bundle(balance: 250000));
      await db.saveBundle(bundle(balance: 300000));
      final loaded = await db.loadBundle('h1');
      expect(loaded!.household.accounts.single.balance,
          Money.dollars(300000));
      expect(await db.householdIds(), ['h1']);
    });

    test('two cloned households coexist, which is how §3.10 compares jobs',
        () async {
      await db.saveBundle(bundle(householdId: 'job-a', balance: 250000));
      await db.saveBundle(bundle(householdId: 'job-b', balance: 400000));
      expect(await db.householdIds(), containsAll(['job-a', 'job-b']));
      expect((await db.loadBundle('job-b'))!.household.accounts.single.balance,
          Money.dollars(400000));
    });

    test('an absent household is null rather than an error', () async {
      expect(await db.loadBundle('nope'), isNull);
    });
  });

  group('§10.1 snapshot trigger rules through storage', () {
    setUp(() async => db.saveBundle(bundle()));

    test('the first snapshot is written', () async {
      final written = await db.recordSnapshot(
          snapshot(id: 's1', at: DateTime(2026, 9, 1), digest: 'aaa'));
      expect(written, isNotNull);
      expect(await db.snapshotsFor('sc1'), hasLength(1));
    });

    test('an unchanged plan writes nothing', () async {
      await db.recordSnapshot(
          snapshot(id: 's1', at: DateTime(2026, 9, 1), digest: 'aaa'));
      final second = await db.recordSnapshot(
          snapshot(id: 's2', at: DateTime(2026, 9, 5), digest: 'aaa'));
      expect(second, isNull);
      expect(await db.snapshotsFor('sc1'), hasLength(1));
    });

    test('a second edit the same day supersedes the first', () async {
      await db.recordSnapshot(
          snapshot(id: 's1', at: DateTime(2026, 9, 6, 9), digest: 'aaa'));
      await db.recordSnapshot(
          snapshot(id: 's2', at: DateTime(2026, 9, 6, 17), digest: 'bbb'));
      final stored = await db.snapshotsFor('sc1');
      expect(stored, hasLength(1));
      expect(stored.single.id, 's2',
          reason: 'the sitting collapses to what the user settled on');
    });

    test('a manual checkpoint always writes and is never superseded',
        () async {
      await db.recordSnapshot(snapshot(
          id: 'pinned',
          at: DateTime(2026, 9, 6, 9),
          digest: 'aaa',
          trigger: SnapshotTrigger.manual));
      await db.recordSnapshot(
          snapshot(id: 's2', at: DateTime(2026, 9, 6, 17), digest: 'bbb'));
      final stored = await db.snapshotsFor('sc1');
      expect(stored.map((s) => s.id), containsAll(['pinned', 's2']));
    });

    test('notReachable survives storage as an absence, not a zero', () async {
      await db.recordSnapshot(
          snapshot(id: 's1', at: DateTime(2026, 9, 1), digest: 'aaa'));
      final stored = (await db.snapshotsFor('sc1')).single;
      expect(stored.retirementYear.pessimistic, isNull);
      expect(stored.fireNumber.pessimistic, isNull);
      expect(stored.retirementYear.expected, 2041);
      expect(stored.fireNumber.expected, Money.dollars(2350000));
    });

    test('money survives storage to the cent', () async {
      await db.recordSnapshot(
          snapshot(id: 's1', at: DateTime(2026, 9, 1), digest: 'aaa'));
      expect((await db.snapshotsFor('sc1')).single.netWorth.cents, 90000000);
    });
  });

  group('§10.2 comparing what is stored', () {
    setUp(() async => db.saveBundle(bundle()));

    test('a comparison reports the movement and the elapsed time', () async {
      await db.recordSnapshot(snapshot(
          id: 's1', at: DateTime(2026, 3, 1), digest: 'aaa',
          expectedYear: 2041));
      await db.recordSnapshot(snapshot(
          id: 's2', at: DateTime(2026, 9, 1), digest: 'bbb',
          expectedYear: 2038));
      final stored = await db.snapshotsFor('sc1');
      final comparison = compareSnapshots(stored.first, stored.last);

      expect(comparison.retirementYear.expected.before, 2041);
      expect(comparison.retirementYear.expected.after, 2038);
      expect(comparison.elapsed!.inDays, greaterThan(180));
      expect(comparison.differsBy, isEmpty,
          reason: 'same scenario, same tax year');
    });

    test('an unreachable side names the transition rather than a difference',
        () async {
      await db.recordSnapshot(snapshot(
          id: 's1', at: DateTime(2026, 3, 1), digest: 'aaa',
          expectedYear: null));
      await db.recordSnapshot(snapshot(
          id: 's2', at: DateTime(2026, 9, 1), digest: 'bbb',
          expectedYear: 2044));
      final stored = await db.snapshotsFor('sc1');
      final delta = compareSnapshots(stored.first, stored.last)
          .retirementYear
          .expected;

      expect(delta.isTransition, isTrue);
      expect(delta.becameReachable, isTrue,
          reason: 'there is no arithmetic between a year and its absence');
    });

    test('comparing across scenarios says so', () async {
      await db.saveBundle(ExportBundle(
        household: household(id: 'job-b'),
        scenarios: [scenario(id: 'sc2', householdId: 'job-b')],
        assetClasses: bundle().assetClasses,
      ));
      await db.recordSnapshot(
          snapshot(id: 's1', at: DateTime(2026, 9, 1), digest: 'aaa'));
      await db.recordSnapshot(snapshot(
          id: 's2',
          at: DateTime(2026, 9, 1),
          digest: 'bbb',
          scenarioId: 'sc2'));

      final a = (await db.snapshotsFor('sc1')).single;
      final b = (await db.snapshotsFor('sc2')).single;
      final comparison = compareSnapshots(a, b);

      expect(comparison.differsBy, contains('scenario'));
      expect(comparison.elapsed, isNull,
          reason: 'two hypotheticals dated the same day have no time axis');
    });
  });
}
