import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every `source` string the app writes has to be one Postgres accepts.
///
/// These columns are `text` with a check constraint, so the device writes them
/// happily, PowerSync syncs them happily, and Postgres refuses with a 23514 —
/// a rejected upload the lifter learns about from a "Not saved" chip some time
/// later, with the row gone.
///
/// Written after `foods.source` was set to 'voice' for a meal read out by the
/// coach. `meal_items.source` accepts 'voice'; `foods.source` does not, and the
/// two lists are different on purpose: one records where the *food* came from,
/// the other how it was *logged*.
void main() {
  final migrations = Directory('../supabase/migrations');

  /// The values each screen and repository can actually write, gathered by
  /// hand because they are literals scattered across call sites. Adding a new
  /// one here without adding it to the migration fails this test; adding it to
  /// the migration without adding it here does nothing, which is the harmless
  /// direction.
  const written = {
    'foods': {'custom', 'off', 'label', 'coach'},
    'meal_items': {'manual', 'barcode', 'voice'},
    'nutrition_targets': {'engine', 'manual'},
  };

  test('every source the app writes is one the schema allows', () {
    for (final MapEntry(key: table, value: values) in written.entries) {
      final allowed = _allowedSources(migrations, table);
      expect(
        allowed,
        isNotEmpty,
        reason: 'no source constraint found for $table — did it move?',
      );
      expect(
        values.difference(allowed),
        isEmpty,
        reason: '$table.source rejects these; Postgres answers 23514 and the '
            'upload is dropped',
      );
    }
  });

  test('the constraint is read, not assumed', () {
    // Proof the parser found something real rather than an empty set that
    // would make every check above pass.
    expect(_allowedSources(migrations, 'foods'), contains('coach'));
    expect(_allowedSources(migrations, 'foods'), isNot(contains('voice')));
    expect(_allowedSources(migrations, 'meal_items'), contains('voice'));
  });
}

/// The values allowed by `check (source in (...))` on [table].
Set<String> _allowedSources(Directory dir, String table) {
  final start = RegExp('create table public\\.$table\\s*\\(');
  final constraint = RegExp(r'check\s*\(source\s+in\s*\(([^)]*)\)', dotAll: true);

  for (final file in dir.listSync().whereType<File>()) {
    if (!file.path.endsWith('.sql')) continue;
    final sql = file.readAsStringSync();
    final opened = start.firstMatch(sql);
    if (opened == null) continue;

    // Only look inside this table's block.
    final body = sql.substring(opened.end);
    final end = body.indexOf('\n);');
    final block = end == -1 ? body : body.substring(0, end);

    final match = constraint.firstMatch(block);
    if (match == null) continue;
    return RegExp("'([a-z_]+)'")
        .allMatches(match.group(1)!)
        .map((m) => m.group(1)!)
        .toSet();
  }
  return const {};
}
