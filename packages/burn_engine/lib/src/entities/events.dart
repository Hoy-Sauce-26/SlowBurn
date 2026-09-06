import '../enums.dart';
import '../types.dart';

/// §3.8. A single dated inflow or outflow.
///
/// Dated to a year rather than spread across one, so in year 0 it fires in full
/// and `frac` does not scale it (§6.4).
class OneTimeEvent {
  final Id id;
  final Id householdId;

  /// Who receives or pays it, and so whose `TaxUnit` its treatment reaches.
  final Id? personId;

  final String label;
  final int year;

  /// Signed: positive inflow, negative outflow.
  final Money amount;

  /// A label; no engine rule branches on it.
  final OneTimeEventKind kind;

  /// Destination for an inflow, source for an outflow. Required for outflows
  /// (invariant 17).
  final Id? accountId;

  final EventTaxTreatment taxTreatment;

  const OneTimeEvent({
    required this.id,
    required this.householdId,
    this.personId,
    required this.label,
    required this.year,
    required this.amount,
    this.kind = OneTimeEventKind.other,
    this.accountId,
    this.taxTreatment = EventTaxTreatment.nonTaxable,
  });

  bool get isOutflow => amount < 0;
}
