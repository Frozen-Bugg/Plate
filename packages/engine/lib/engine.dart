/// Overload's growth engine.
///
/// Every load, rep target and stall verdict the app or the coach shows comes
/// from here. Pure Dart and deterministic: no Flutter, no database, no clock,
/// no randomness — the same inputs always give the same answer, which is what
/// makes the numbers testable and the coach auditable.
///
/// See docs/PLAN.md §5 for the models and the arithmetic.
library;

export 'src/e1rm.dart';
export 'src/plates.dart';
export 'src/progression.dart';
export 'src/readiness.dart';
export 'src/set_log.dart';
export 'src/stall.dart';
export 'src/trend.dart';
