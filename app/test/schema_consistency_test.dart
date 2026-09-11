import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/core/db/powersync_schema.dart';
import 'package:powersync/powersync.dart' show ColumnType;

/// PowerSync creates the tables; Drift only queries them. If the two drift
/// apart, queries fail at runtime on the device, so catch it here.
void main() {
  test('Drift tables match the PowerSync schema', () {
    // Never opened: only the table metadata is read.
    final db = AppDatabase(
      DatabaseConnection.delayed(Completer<DatabaseConnection>().future),
    );

    final powerSync = {
      for (final table in schema.tables)
        table.name: {for (final c in table.columns) c.name: c.type},
    };
    final drift = {
      for (final table in db.allTables)
        table.actualTableName: {
          for (final c in table.$columns)
            if (c.name != 'id') c.name: _storedAs(c.type),
        },
    };

    expect(drift, equals(powerSync));
  });
}

/// How a Drift column is stored in SQLite, given build.yaml's
/// store_date_time_values_as_text: true.
ColumnType _storedAs(Object type) => switch (type) {
      DriftSqlType.string || DriftSqlType.dateTime => ColumnType.text,
      DriftSqlType.int || DriftSqlType.bool || DriftSqlType.bigInt =>
        ColumnType.integer,
      DriftSqlType.double => ColumnType.real,
      _ => throw ArgumentError('No PowerSync column type for $type'),
    };
