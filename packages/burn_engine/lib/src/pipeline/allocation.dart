/// §3.9 and §3.4. The return an account earns, blended across its allocation.
library;

import '../entities/account.dart';
import '../entities/assumptions.dart';
import '../enums.dart';
import '../types.dart';

/// The weights an account's allocation resolves to, whichever mode it uses.
Iterable<({AssetClass cls, double weight})> _blend(
  Account account,
  Map<Id, AssetClass> classes, {
  bool retired = false,
}) sync* {
  switch (account.allocationMode) {
    case AllocationMode.singleClass:
      final cls = classes[account.allocationIn(retired: retired)];
      if (cls != null) yield (cls: cls, weight: 1.0);
    case AllocationMode.weighted:
      for (final w in account.allocationWeights) {
        final cls = classes[w.assetClassId];
        if (cls != null) yield (cls: cls, weight: w.weight);
      }
  }
}

/// The account's real return for a band, blended per its `allocationMode`.
Rate blendedReturn(
  Account account,
  Map<Id, AssetClass> classes,
  BandName band, {
  bool retired = false,
}) =>
    _blend(account, classes, retired: retired)
        .fold(0.0, (sum, e) => sum + e.weight * e.cls.returnFor(band));

/// The share of balance paid out as distributions each year (§3.9).
Rate blendedIncomeYield(Account account, Map<Id, AssetClass> classes,
        {bool retired = false}) =>
    _blend(account, classes, retired: retired)
        .fold(0.0, (sum, e) => sum + e.weight * e.cls.incomeYield);

/// The portion of that yield taxed at preferential rates (§4.3.3).
///
/// Weighted by each class's *yield*, not by its share of the balance: a class
/// throwing off no income contributes no dividends to qualify.
Rate blendedQualifiedIncomeFraction(
  Account account,
  Map<Id, AssetClass> classes, {
  bool retired = false,
}) {
  var yieldTotal = 0.0;
  var qualifiedTotal = 0.0;
  for (final e in _blend(account, classes, retired: retired)) {
    yieldTotal += e.weight * e.cls.incomeYield;
    qualifiedTotal +=
        e.weight * e.cls.incomeYield * e.cls.qualifiedIncomeFraction;
  }
  return yieldTotal == 0 ? 0 : qualifiedTotal / yieldTotal;
}

/// The appreciation half of the return, the distributions taken out (§3.9).
Rate blendedAppreciation(
  Account account,
  Map<Id, AssetClass> classes,
  BandName band, {
  bool retired = false,
}) =>
    blendedReturn(account, classes, band, retired: retired) -
    blendedIncomeYield(account, classes, retired: retired);
