import 'dart:async';

import 'package:burn_engine/burn_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';
import 'providers.dart';

/// Loading what was there last time, and writing it back as it changes.
///
/// §1.4 makes local-only a domain rule, so this is the whole of persistence:
/// there is no account, no sync and nowhere else the plan exists. That also
/// means losing it is unrecoverable, which is why the write happens on every
/// change rather than on an explicit save the user might not reach.
final databaseProvider = FutureProvider<Database>((ref) async {
  final db = await Database.open();
  ref.onDispose(db.close);
  return db;
});

/// Whether the stored plan has been read yet. The app should not write over
/// what is on disk with an empty household while it is still loading it.
enum LoadState { loading, ready, failed }

final loadStateProvider =
    NotifierProvider<LoadStateNotifier, LoadState>(LoadStateNotifier.new);

class LoadStateNotifier extends Notifier<LoadState> {
  @override
  LoadState build() => LoadState.loading;
  void set(LoadState value) => state = value;
}

/// Reads the stored plan into the providers, then keeps writing it back.
///
/// Held by the app shell so it lives as long as the session does.
class Persistence {
  Persistence(this._ref);

  final Ref _ref;
  Timer? _pending;
  var _loaded = false;

  /// How long to wait after a change before writing. Long enough that typing a
  /// salary is one write rather than six, short enough that closing the window
  /// straight afterwards has already saved.
  static const debounce = Duration(milliseconds: 400);

  Future<void> start() async {
    try {
      final db = await _ref.read(databaseProvider.future);
      final ids = await db.householdIds();
      if (ids.isNotEmpty) {
        final bundle = await db.loadBundle(ids.first);
        if (bundle != null) {
          _ref
              .read(householdProvider.notifier)
              .replace(withSavingsSplit(bundle));
          if (bundle.scenarios.isNotEmpty) {
            _ref.read(scenarioProvider.notifier).replace(bundle.scenarios.first);
          }
          if (bundle.assetClasses.isNotEmpty) {
            _ref
                .read(assetClassesProvider.notifier)
                .replace(bundle.assetClasses);
          }
          final setup = await db.loadSetup(ids.first);
          if (setup != null) {
            _ref.read(setupProgressProvider.notifier).replace(setup);
          }
        }
      }
      _loaded = true;
      _ref.read(loadStateProvider.notifier).set(LoadState.ready);
      _watch();
    } catch (_) {
      // A plan that cannot be read is worse than one that cannot be written:
      // the app still runs, and the next successful save will fix it.
      _ref.read(loadStateProvider.notifier).set(LoadState.failed);
    }
  }

  /// A plan written before savings and idle cash were separate classes has its
  /// savings accounts pointing at the one cash class there was. That was never
  /// a choice anybody made, since there was nothing to choose between, so it is
  /// moved to the class that now describes it.
  static Household withSavingsSplit(ExportBundle bundle) {
    final alreadySplit = bundle.assetClasses
        .any((c) => c.label == AssetClassLabel.savings);
    if (alreadySplit) return bundle.household;

    final savings = AssetClassesNotifier.defaults
        .firstWhere((c) => c.label == AssetClassLabel.savings);
    final idle = bundle.assetClasses
        .where((c) => c.label == AssetClassLabel.cash)
        .map((c) => c.id)
        .toSet();

    return bundle.household.copyWith(
      accounts: [
        for (final account in bundle.household.accounts)
          if (account.kind == AccountKind.cashSavings &&
              idle.contains(account.assetAllocationId))
            account.withAllocation(savings.id)
          else
            account,
      ],
    );
  }

  void _watch() {
    _ref.listen(householdProvider, (_, _) => _schedule());
    _ref.listen(scenarioProvider, (_, _) => _schedule());
    _ref.listen(assetClassesProvider, (_, _) => _schedule());
    _ref.listen(setupProgressProvider, (_, _) => _schedule());
  }

  void _schedule() {
    if (!_loaded) return;
    _pending?.cancel();
    _pending = Timer(debounce, save);
  }

  /// Writes now rather than on the next tick, for the paths that cannot wait:
  /// the window closing, and an explicit save.
  Future<void> save() async {
    _pending?.cancel();
    if (!_loaded) return;
    final db = await _ref.read(databaseProvider.future);
    final household = _ref.read(householdProvider);
    await db.saveBundle(ExportBundle(
      household: household,
      scenarios: [_ref.read(scenarioProvider)],
      assetClasses: _ref.read(assetClassesProvider),
    ));
    await db.saveSetup(household.id, _ref.read(setupProgressProvider));
  }

  void dispose() => _pending?.cancel();
}

final persistenceProvider = Provider<Persistence>((ref) {
  final p = Persistence(ref);
  ref.onDispose(p.dispose);
  return p;
});
