import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/sync/upload_mapping.dart';

/// Every `jsonb` and array column in the schema has to be listed in
/// `jsonColumns`, and a person remembering is not a mechanism.
///
/// The boolean version of this check can read Drift's own metadata, because a
/// boolean is a distinct Drift type. jsonb cannot: PowerSync stores it as text
/// and Drift sees a `TextColumn`, identical to every other string. So the
/// source of truth is the migration, which is where the column is actually
/// declared `jsonb`.
///
/// Getting this wrong is quiet. PostgREST takes the JSON *string* and Postgres
/// stores it as a jsonb string rather than an object — no error, no rejection,
/// and a `payload` that reads back as `"{\"weeks\":1}"` instead of an object.
void main() {
  final migrations = Directory('../supabase/migrations');

  test('every jsonb and array column is registered for upload', () {
    final declared = _columnsByType(migrations, RegExp(r'jsonb|text\[\]'));
    expect(declared, isNotEmpty, reason: 'found no migrations to read');

    final missing = [
      for (final MapEntry(key: table, value: columns) in declared.entries)
        for (final column in columns)
          if (!(jsonColumns[table]?.contains(column) ?? false))
            '$table.$column',
    ];

    expect(
      missing,
      isEmpty,
      reason: 'Add these to jsonColumns in lib/core/sync/upload_mapping.dart, '
          'or Postgres stores the JSON text as a string and says nothing.',
    );
  });

  test('nothing is registered that the schema does not declare', () {
    // The other direction: a column that was renamed or dropped leaves a stale
    // entry that decodes something which is now ordinary text.
    final declared = _columnsByType(migrations, RegExp(r'jsonb|text\[\]'));
    final stale = [
      for (final MapEntry(key: table, value: columns) in jsonColumns.entries)
        for (final column in columns)
          if (!(declared[table]?.contains(column) ?? false)) '$table.$column',
    ];

    expect(
      stale,
      isEmpty,
      reason: 'These are in jsonColumns but are not jsonb or an array in any '
          'migration. Remove them, or the connector decodes plain text.',
    );
  });
}

/// Column names per table whose declared type matches [type].
///
/// A deliberately small parser: it walks `create table public.x (` blocks and
/// reads the first two words of each line. That is enough for this schema,
/// where every column is declared on its own line, and it fails loudly rather
/// than silently if that ever stops being true — the first test asserts it
/// found something.
Map<String, Set<String>> _columnsByType(Directory dir, RegExp type) {
  final found = <String, Set<String>>{};
  final table = RegExp(r'create table public\.(\w+)\s*\(');
  final column = RegExp(r'^\s{2,}(\w+)\s+([\w\[\]]+)');

  for (final file in dir.listSync().whereType<File>()) {
    if (!file.path.endsWith('.sql')) continue;
    String? current;
    for (final line in file.readAsLinesSync()) {
      if (table.firstMatch(line) case final match?) {
        current = match.group(1);
        continue;
      }
      if (current == null) continue;
      if (line.startsWith(');')) {
        current = null;
        continue;
      }
      if (column.firstMatch(line) case final match?) {
        if (type.hasMatch(match.group(2)!)) {
          (found[current] ??= {}).add(match.group(1)!);
        }
      }
    }
  }
  return found;
}
