import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Reads a bundled ruleset off the asset bundle and hands it to the engine.
///
/// The split is deliberate: `burn_engine` parses, and only this file knows what
/// an asset is. That is what keeps the engine pure Dart and testable without a
/// widget harness.
class TaxYearService {
  static const _dir = 'assets/tax_years';

  final _cache = <String, TaxYear>{};

  /// The ruleset the app projects under by default. §7.1 picks the latest
  /// bundled year; a scenario may pin an older one through `taxYearId`.
  static const defaultTaxYearId = 'us-2026';

  Future<TaxYear> load(String taxYearId) async {
    final cached = _cache[taxYearId];
    if (cached != null) return cached;

    final year = taxYearId.split('-').last;
    final source = await rootBundle.loadString('$_dir/$year.json');
    final parsed = parseTaxYear(source);
    if (parsed.id != taxYearId) {
      throw TaxYearFormatException(
        'assets/$_dir/$year.json declares "${parsed.id}", not "$taxYearId"',
      );
    }
    return _cache[taxYearId] = parsed;
  }
}
