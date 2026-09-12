import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/core/db/powersync_schema.dart';
import 'package:overload/core/sync/upload_mapping.dart';

/// Every boolean that syncs has to be listed in `boolColumns`, and a person
/// remembering to add it is not a mechanism.
///
/// PowerSync stores booleans as 0/1 integers, and PostgREST will not take an
/// integer for a `boolean` column — the upload is rejected as a 22xxx and
/// dropped. The rule is written in CLAUDE.md; this is what enforces it. It was
/// added after `foods.favourite` and `recipes.favourite` were both missed in
/// the same commit.
void main() {
  test('every synced boolean column is registered for upload', () {
    // Never opened: only the table metadata is read.
    final db = AppDatabase(
      DatabaseConnection.delayed(Completer<DatabaseConnection>().future),
    );

    final localOnly = {
      for (final table in schema.tables)
        if (table.localOnly) table.name,
    };

    final missing = <String>[];
    for (final table in db.allTables) {
      final name = table.actualTableName;
      // A local-only table never reaches Postgres, so nothing to convert.
      if (localOnly.contains(name)) continue;

      for (final column in table.$columns) {
        if (column.type != DriftSqlType.bool) continue;
        if (boolColumns[name]?.contains(column.name) ?? false) continue;
        missing.add('$name.${column.name}');
      }
    }

    expect(
      missing,
      isEmpty,
      reason: 'Add these to boolColumns in lib/core/sync/upload_mapping.dart, '
          'or Postgres will refuse the upload and the connector will drop it.',
    );
  });

  test('nothing is registered that is not a boolean any more', () {
    final db = AppDatabase(
      DatabaseConnection.delayed(Completer<DatabaseConnection>().future),
    );
    final actual = {
      for (final table in db.allTables)
        for (final column in table.$columns)
          if (column.type == DriftSqlType.bool)
            '${table.actualTableName}.${column.name}',
    };

    final stale = [
      for (final MapEntry(key: table, value: columns) in boolColumns.entries)
        for (final column in columns)
          if (!actual.contains('$table.$column')) '$table.$column',
    ];

    expect(stale, isEmpty,
        reason: 'These are listed in boolColumns but are no longer booleans.');
  });
}
