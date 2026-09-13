import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';

/// Every column the Coach API asks PostgREST for has to exist.
///
/// This test was written because one did not. `progression_state.last_trained_on`
/// was invented, typechecked fine, passed all 64 tests — because those tests run
/// against an in-memory fake — and failed the first time a real question was
/// asked, as a 42703 in the middle of an answer.
///
/// The fake is still the right way to test behaviour; it just cannot know what
/// Postgres has. So the column names are checked against the migrations, which
/// is where they are actually declared.

const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const migrations = path.join(here, '..', '..', 'supabase', 'migrations');
const dataSource = readFileSync(path.join(here, '..', 'src', 'data.ts'), 'utf8');

/// table → columns, read out of the `create table` blocks.
function schemaFromMigrations(): Map<string, Set<string>> {
  const tables = new Map<string, Set<string>>();
  const start = /create table public\.(\w+)\s*\(/;
  // A column line: two spaces, a name, then a type. Constraint lines start with
  // a keyword instead, and are filtered by the list below.
  const column = /^\s{2}([a-z_]\w*)\s+[a-z]/;
  const keywords = new Set([
    'unique', 'check', 'foreign', 'primary', 'constraint', 'exclude',
  ]);

  for (const file of readdirSync(migrations).filter((f) => f.endsWith('.sql'))) {
    let current: string | undefined;
    for (const line of readFileSync(path.join(migrations, file), 'utf8').split(/\r?\n/)) {
      const opened = start.exec(line);
      if (opened) {
        current = opened[1];
        tables.set(current, tables.get(current) ?? new Set());
        continue;
      }
      if (!current) continue;
      if (line.startsWith(');')) {
        current = undefined;
        continue;
      }
      const match = column.exec(line);
      if (match && !keywords.has(match[1])) tables.get(current)!.add(match[1]);
    }
  }
  return tables;
}

/// Every (table, column) the source asks for.
///
/// Deliberately a small parser over the query strings rather than anything
/// clever: the queries are string literals a few lines long, and a parser that
/// understood PostgREST fully would be more likely to be wrong than they are.
function requestedColumns(source: string): { table: string; column: string }[] {
  const asked: { table: string; column: string }[] = [];

  // Each query starts `'<table>?select=...`. Joining a multi-line literal first
  // so a query split across `+` is read whole.
  const joined = source.replace(/'\s*\+\s*\n\s*'/g, '');

  for (const match of joined.matchAll(/'(\w+)\?select=([^'`]*)/g)) {
    const table = match[1];
    const rest = match[2];

    // The select list runs to the first & that starts a filter.
    const [selectList, ...filters] = rest.split('&');

    // Embedded resources: `foods(name)` reads name from foods.
    for (const embed of selectList.matchAll(/(\w+)!?\w*\(([^)]*)\)/g)) {
      for (const column of embed[2].split(',')) {
        const name = column.trim().replace(/!inner$/, '');
        if (name && !name.includes('(')) {
          asked.push({ table: embed[1], column: name });
        }
      }
    }

    // Plain columns, with the embedded ones removed.
    const plain = selectList.replace(/(\w+)!?\w*\([^)]*\)/g, '');
    for (const column of plain.split(',')) {
      const name = column.trim();
      if (name && /^[a-z_]\w*$/.test(name)) asked.push({ table, column: name });
    }

    // Filters and ordering: `&rollup_on=gte.x`, `&order=name.asc`. Dotted
    // paths like `meals.meal_on` belong to the embedded table.
    for (const filter of filters) {
      const [left] = filter.split('=');
      if (!left || left === 'limit' || left === 'offset') continue;
      const field = left === 'order' ? filter.split('=')[1]?.split('.')[0] : left;
      if (!field) continue;
      if (field.includes('.')) {
        const parts = field.split('.');
        const column = parts.pop()!;
        const owner = parts.pop()!;
        if (/^[a-z_]\w*$/.test(column)) asked.push({ table: owner, column });
      } else if (/^[a-z_]\w*$/.test(field)) {
        asked.push({ table, column: field });
      }
    }
  }
  return asked;
}

test('the migrations parse into something worth checking against', () => {
  const schema = schemaFromMigrations();
  // A parser that silently found nothing would make every check below pass.
  assert.ok(schema.size > 15, `only found ${schema.size} tables`);
  assert.ok(schema.get('daily_rollup')?.has('trend_weight_kg'));
  assert.ok(schema.get('sets')?.has('e1rm_kg'));
  assert.ok(!schema.get('progression_state')?.has('last_trained_on'));
});

test('the query parser finds the queries', () => {
  const asked = requestedColumns(dataSource);
  assert.ok(asked.length > 40, `only found ${asked.length} columns`);
  assert.ok(asked.some((a) => a.table === 'daily_rollup' && a.column === 'steps'));
  assert.ok(asked.some((a) => a.table === 'exercises' && a.column === 'name'));
});

test('every column the coach asks for exists', () => {
  const schema = schemaFromMigrations();
  const missing: string[] = [];

  for (const { table, column } of requestedColumns(dataSource)) {
    const columns = schema.get(table);
    if (!columns) {
      missing.push(`${table} (no such table)`);
      continue;
    }
    if (!columns.has(column)) missing.push(`${table}.${column}`);
  }

  assert.deepEqual(
    [...new Set(missing)],
    [],
    'These are queried in src/data.ts but not declared in any migration. ' +
      'PostgREST answers 42703 and the coach fails mid-answer.',
  );
});

test('the check would have caught the column that got through', () => {
  // Proof the test is not vacuous: the exact mistake it exists to prevent.
  const withTypo = dataSource.replace(
    "'updated_at,exercises(name)&deleted_at=is.null'",
    "'last_trained_on,exercises(name)&deleted_at=is.null'",
  );
  assert.notEqual(withTypo, dataSource, 'the fixture no longer matches the source');

  const schema = schemaFromMigrations();
  const caught = requestedColumns(withTypo).some(
    ({ table, column }) => !schema.get(table)?.has(column),
  );
  assert.ok(caught, 'the invented column would still slip through');
});
