import 'dart:convert';

/// Columns that PowerSync stores as JSON text on the device but that are
/// arrays / jsonb in Postgres. They must be decoded before upload, otherwise
/// PostgREST receives a string and Postgres rejects it.
const jsonColumns = <String, Set<String>>{
  'profiles': {'equipment', 'injuries'},
  'exercises': {'primary_muscles', 'secondary_muscles'},
  'coach_messages': {'tool_calls'},
  'ai_proposals': {'payload'},
};

/// Postgres booleans arrive on the device as 0/1 integers.
const boolColumns = <String, Set<String>>{
  'exercises': {'unilateral'},
  'sets': {'is_pr'},
  'foods': {'favourite'},
  'recipes': {'favourite'},
  'ai_proposals': {'validated'},
};

/// Converts a PowerSync CRUD payload for [table] into the JSON body Supabase expects.
Map<String, dynamic> toSupabaseRow(String table, Map<String, dynamic> data) {
  final json = jsonColumns[table] ?? const <String>{};
  final bools = boolColumns[table] ?? const <String>{};
  return {
    for (final MapEntry(:key, :value) in data.entries)
      key: switch (value) {
        final String s when json.contains(key) => jsonDecode(s),
        final int i when bools.contains(key) => i != 0,
        _ => value,
      },
  };
}
