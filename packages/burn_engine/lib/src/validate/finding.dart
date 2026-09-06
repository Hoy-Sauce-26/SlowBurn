/// What validation reports, and how loudly (§12).
///
/// The document's posture is warn-don't-block: a household that trips an
/// invariant still projects, and the finding rides along so the UI can say what
/// is wrong. Only [Severity.blocking] findings describe data the engine cannot
/// run on at all.
library;

enum Severity {
  /// The projection cannot be trusted and the engine should not run.
  blocking,

  /// The projection runs and a number may be off.
  warning,
}

class Finding {
  /// Which invariant, so the message can be traced to §12.
  final int invariant;
  final Severity severity;
  final String message;

  /// The entity id the finding is about, where there is one.
  final String? entityId;

  const Finding(
    this.invariant,
    this.severity,
    this.message, {
    this.entityId,
  });

  @override
  String toString() =>
      'invariant $invariant (${severity.name}): $message'
      '${entityId == null ? '' : ' [$entityId]'}';
}
