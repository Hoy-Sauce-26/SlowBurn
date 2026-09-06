import 'package:flutter_test/flutter_test.dart';
import 'package:slow_burn/services/tax_year_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled ruleset loads off the asset bundle', () async {
    final taxYear =
        await TaxYearService().load(TaxYearService.defaultTaxYearId);
    expect(taxYear.year, 2026);
    expect(taxYear.oasdiRate, 0.062);
  });

  test('a ruleset whose id disagrees with its filename is refused', () async {
    expect(
      () => TaxYearService().load('us-1999'),
      throwsA(anything),
    );
  });
}
