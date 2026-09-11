import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/sync/upload_mapping.dart';

void main() {
  test('decodes array columns and 0/1 booleans for exercises', () {
    expect(
      toSupabaseRow('exercises', {
        'name': 'Landmine Press',
        'primary_muscles': '["front_delts","chest"]',
        'secondary_muscles': '[]',
        'equipment': 'barbell',
        'unilateral': 1,
        'load_step_kg': 2.5,
      }),
      {
        'name': 'Landmine Press',
        'primary_muscles': ['front_delts', 'chest'],
        'secondary_muscles': <dynamic>[],
        'equipment': 'barbell',
        'unilateral': true,
        'load_step_kg': 2.5,
      },
    );
  });

  test('profiles.equipment is an array even though exercises.equipment is not', () {
    expect(
      toSupabaseRow('profiles', {
        'equipment': '["barbell","dumbbell"]',
        'injuries': '[{"area":"left_shoulder"}]',
      }),
      {
        'equipment': ['barbell', 'dumbbell'],
        'injuries': [
          {'area': 'left_shoulder'},
        ],
      },
    );
  });

  test('nulls and unlisted columns pass through unchanged', () {
    final row = {'is_pr': 0, 'weight_kg': null, 'reps': 8, 'kind': 'working'};
    expect(toSupabaseRow('sets', row), {
      'is_pr': false,
      'weight_kg': null,
      'reps': 8,
      'kind': 'working',
    });
    expect(toSupabaseRow('sessions', {'notes': '[not json]'}), {
      'notes': '[not json]',
    });
  });
}
