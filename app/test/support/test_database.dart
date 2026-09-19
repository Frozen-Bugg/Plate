import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:overload/core/db/app_database.dart';

/// A real, in-memory [AppDatabase] for tests that need actual SQL rather than
/// a faked stream — repository logic, reorder transactions, the engine's
/// numbers coming back out of a real join.
///
/// The production [AppDatabase] deliberately creates nothing on `onCreate`,
/// because PowerSync owns table creation on a real device (see the comment on
/// `AppDatabase.migration`). Here there is no PowerSync, so this subclass asks
/// Drift to create its own schema instead. That schema is what
/// `schema_consistency_test.dart` already proves matches PowerSync's
/// column-for-column, so it is a faithful stand-in — every repository method
/// under test runs unmodified, against real SQL, and only the table-creation
/// step differs from a device.
class TestDatabase extends AppDatabase {
  TestDatabase() : super(NativeDatabase.memory());

  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}
