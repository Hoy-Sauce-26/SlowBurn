import 'dart:convert';
import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'readiness.dart';

/// Local storage. §1.4 makes local-only a domain rule, so there is no sync, no
/// telemetry, and no network client anywhere near this file.
///
/// The schema is deliberately coarse: one row per household and per scenario,
/// each holding the engine's own JSON. Normalising seventeen entity types into
/// seventeen tables would buy queries nothing, since the engine always loads a
/// whole household anyway, and would put a migration in the way of every
/// domain change.
///
/// Snapshots are the exception. They are queried by scenario and by date, they
/// accumulate, and §10.2 compares any two, so they get real columns.
class Database {
  Database._(this._db);

  final sqflite.Database _db;

  static const _schemaVersion = 2;

  /// sqflite ships a mobile implementation only. This is what reaches macOS,
  /// Windows and Linux, and it must run before any database is opened.
  static void initialiseForPlatform() {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  static Future<Database> open({String fileName = 'slow_burn.db'}) async {
    initialiseForPlatform();
    final dir = await getApplicationSupportDirectory();
    final db = await openDatabase(
      p.join(dir.path, fileName),
      version: _schemaVersion,
      onCreate: (db, _) => _create(db),
      onUpgrade: _upgrade,
    );
    return Database._(db);
  }

  /// An in-memory database, for tests and for a throwaway session.
  static Future<Database> openInMemory() async {
    initialiseForPlatform();
    final db = await openDatabase(
      inMemoryDatabasePath,
      version: _schemaVersion,
      onCreate: (db, _) => _create(db),
      onUpgrade: _upgrade,
    );
    return Database._(db);
  }

  /// A plan written before setup existed belongs to somebody who has already
  /// been through the app, so it arrives ready rather than back at step one.
  static Future<void> _upgrade(sqflite.Database db, int from, int to) async {
    if (from < 2) {
      await _createSetup(db);
      final ids = await db.query('households', columns: ['id']);
      for (final row in ids) {
        await db.insert('setup', {
          'householdId': row['id'],
          'passed': '',
          'declaredReady': 1,
        });
      }
    }
  }

  static Future<void> _createSetup(sqflite.Database db) => db.execute('''
      CREATE TABLE setup (
        householdId   TEXT PRIMARY KEY,
        passed        TEXT NOT NULL,
        declaredReady INTEGER NOT NULL,
        FOREIGN KEY (householdId) REFERENCES households(id) ON DELETE CASCADE
      )''');

  static Future<void> _create(sqflite.Database db) async {
    await db.execute('''
      CREATE TABLE households (
        id     TEXT PRIMARY KEY,
        body   TEXT NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE scenarios (
        id           TEXT PRIMARY KEY,
        householdId  TEXT NOT NULL,
        label        TEXT NOT NULL,
        body         TEXT NOT NULL,
        FOREIGN KEY (householdId) REFERENCES households(id) ON DELETE CASCADE
      )''');
    await db.execute('''
      CREATE TABLE assetClasses (
        id    TEXT PRIMARY KEY,
        body  TEXT NOT NULL
      )''');
    // Snapshots are immutable once written and never edited in place
      // (invariant 18): a plan change produces a new row.
    await db.execute('''
      CREATE TABLE snapshots (
        id                        TEXT PRIMARY KEY,
        scenarioId                TEXT NOT NULL,
        asOfDate                  TEXT NOT NULL,
        trigger                   TEXT NOT NULL,
        label                     TEXT,
        inputDigest               TEXT NOT NULL,
        taxYearId                 TEXT NOT NULL,
        retirementYear            TEXT NOT NULL,
        fireNumber                TEXT NOT NULL,
        sustainableLevelSpending  TEXT NOT NULL,
        netWorth                  INTEGER NOT NULL,
        liquidNetWorth            INTEGER NOT NULL,
        investableNetWorth        INTEGER NOT NULL,
        afterTaxLiquidNetWorth    INTEGER NOT NULL,
        savingsRate               REAL NOT NULL,
        FOREIGN KEY (scenarioId) REFERENCES scenarios(id) ON DELETE CASCADE
      )''');
    await db.execute(
        'CREATE INDEX snapshots_by_scenario ON snapshots(scenarioId, asOfDate)');
    await _createSetup(db);
  }

  // --- setup progress -------------------------------------------------------

  Future<void> saveSetup(String householdId, SetupProgress progress) =>
      _db.insert(
        'setup',
        {
          'householdId': householdId,
          'passed': progress.passed.map((s) => s.name).join(','),
          'declaredReady': progress.declaredReady ? 1 : 0,
        },
        conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
      );

  Future<SetupProgress?> loadSetup(String householdId) async {
    final rows = await _db
        .query('setup', where: 'householdId = ?', whereArgs: [householdId]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    final names = (row['passed'] as String).split(',').where((n) => n.isNotEmpty);
    return SetupProgress(
      passed: {
        for (final n in names)
          ...SetupStep.values.where((s) => s.name == n),
      },
      declaredReady: (row['declaredReady'] as int) == 1,
    );
  }

  Future<void> close() => _db.close();

  // --- households and scenarios ---------------------------------------------

  /// Writes a whole bundle. §3.10's cloning is what differing household data
  /// means, so a household is saved once however many scenarios point at it.
  Future<void> saveBundle(ExportBundle bundle) async {
    final map = exportToMap(bundle);
    await _db.transaction((txn) async {
      await txn.insert(
        'households',
        {'id': bundle.household.id, 'body': jsonEncode(map['household'])},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final scenario in (map['scenarios'] as List<dynamic>)) {
        await txn.insert(
          'scenarios',
          {
            'id': scenario['id'],
            'householdId': scenario['householdId'],
            'label': scenario['label'],
            'body': jsonEncode(scenario),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final assetClass in (map['assetClasses'] as List<dynamic>)) {
        await txn.insert(
          'assetClasses',
          {'id': assetClass['id'], 'body': jsonEncode(assetClass)},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<ExportBundle?> loadBundle(String householdId) async {
    final households = await _db
        .query('households', where: 'id = ?', whereArgs: [householdId]);
    if (households.isEmpty) return null;

    final scenarios = await _db
        .query('scenarios', where: 'householdId = ?', whereArgs: [householdId]);
    final classes = await _db.query('assetClasses');

    return importFromMap({
      'schemaVersion': exportSchemaVersion,
      'household': jsonDecode(households.first['body'] as String),
      'scenarios': [
        for (final row in scenarios) jsonDecode(row['body'] as String),
      ],
      'assetClasses': [
        for (final row in classes) jsonDecode(row['body'] as String),
      ],
    });
  }

  Future<List<String>> householdIds() async {
    final rows = await _db.query('households', columns: ['id']);
    return [for (final row in rows) row['id'] as String];
  }

  // --- snapshots -------------------------------------------------------------

  Future<List<ProjectionSnapshot>> snapshotsFor(String scenarioId) async {
    final rows = await _db.query('snapshots',
        where: 'scenarioId = ?', whereArgs: [scenarioId], orderBy: 'asOfDate');
    return [for (final row in rows) _readSnapshot(row)];
  }

  /// §10.1. Applies the trigger rules and returns what was written, or null
  /// where nothing had changed.
  Future<ProjectionSnapshot?> recordSnapshot(
    ProjectionSnapshot snapshot,
  ) async {
    final existing = await snapshotsFor(snapshot.scenarioId);
    final decision = snapshotDecision(
      existing: existing,
      trigger: snapshot.trigger,
      digest: snapshot.inputDigest,
      asOfDate: snapshot.asOfDate,
    );
    if (decision.action == SnapshotAction.skip) return null;

    await _db.transaction((txn) async {
      if (decision.supersedes != null) {
        await txn.delete('snapshots',
            where: 'id = ?', whereArgs: [decision.supersedes!.id]);
      }
      await txn.insert('snapshots', _writeSnapshot(snapshot));
    });
    return snapshot;
  }

  Map<String, Object?> _writeSnapshot(ProjectionSnapshot s) => {
        'id': s.id,
        'scenarioId': s.scenarioId,
        'asOfDate': s.asOfDate.toIso8601String(),
        'trigger': s.trigger.name,
        'label': s.label,
        'inputDigest': s.inputDigest,
        'taxYearId': s.taxYearId,
        'retirementYear': jsonEncode(_bandToJson(s.retirementYear, (v) => v)),
        'fireNumber':
            jsonEncode(_bandToJson(s.fireNumber, (v) => v.cents)),
        'sustainableLevelSpending': jsonEncode(
            _bandToJson(s.sustainableLevelSpending, (v) => v.cents)),
        'netWorth': s.netWorth.cents,
        'liquidNetWorth': s.liquidNetWorth.cents,
        'investableNetWorth': s.investableNetWorth.cents,
        'afterTaxLiquidNetWorth': s.afterTaxLiquidNetWorth.cents,
        'savingsRate': s.savingsRate,
      };

  ProjectionSnapshot _readSnapshot(Map<String, Object?> row) =>
      ProjectionSnapshot(
        id: row['id'] as String,
        scenarioId: row['scenarioId'] as String,
        asOfDate: DateTime.parse(row['asOfDate'] as String),
        trigger: SnapshotTrigger.values
            .firstWhere((t) => t.name == row['trigger'] as String),
        label: row['label'] as String?,
        inputDigest: row['inputDigest'] as String,
        taxYearId: row['taxYearId'] as String,
        retirementYear: _bandFromJson(
            row['retirementYear'] as String, (v) => v as int),
        fireNumber:
            _bandFromJson(row['fireNumber'] as String, (v) => Money(v as int)),
        sustainableLevelSpending: _bandFromJson(
            row['sustainableLevelSpending'] as String,
            (v) => Money(v as int)),
        netWorth: Money(row['netWorth'] as int),
        liquidNetWorth: Money(row['liquidNetWorth'] as int),
        investableNetWorth: Money(row['investableNetWorth'] as int),
        afterTaxLiquidNetWorth: Money(row['afterTaxLiquidNetWorth'] as int),
        savingsRate: row['savingsRate'] as double,
      );
}

/// A band of possibly-unreachable values. `null` survives the round trip, which
/// is what keeps `notReachable` distinct from zero (§8.2).
Map<String, dynamic> _bandToJson<T>(
  Band<Reachable<T>> band,
  Object Function(T) encode,
) =>
    {
      'pessimistic':
          band.pessimistic == null ? null : encode(band.pessimistic as T),
      'expected': band.expected == null ? null : encode(band.expected as T),
      'optimistic':
          band.optimistic == null ? null : encode(band.optimistic as T),
    };

Band<Reachable<T>> _bandFromJson<T>(
  String source,
  T Function(Object) decode,
) {
  final j = jsonDecode(source) as Map<String, dynamic>;
  T? read(String key) => j[key] == null ? null : decode(j[key] as Object);
  return Band(
    pessimistic: read('pessimistic'),
    expected: read('expected'),
    optimistic: read('optimistic'),
  );
}
