-- Starter exercise library (user_id null = shared, read-only for users).
-- Phase 1 expands this to ~300 movements; keep names unique so re-seeding can upsert by name.

create unique index exercises_library_name_idx
  on public.exercises (lower(name)) where user_id is null;

insert into public.exercises
  (name, primary_muscles, secondary_muscles, equipment, pattern, unilateral, load_step_kg)
values
  ('Back Squat',              '{quads,glutes}',        '{adductors,lower_back}', 'barbell',    'squat',           false, 5),
  ('Front Squat',             '{quads}',               '{glutes,upper_back}',    'barbell',    'squat',           false, 2.5),
  ('Leg Press',               '{quads,glutes}',        '{}',                     'machine',    'squat',           false, 5),
  ('Bulgarian Split Squat',   '{quads,glutes}',        '{adductors}',            'dumbbell',   'lunge',           true,  2),
  ('Conventional Deadlift',   '{glutes,hamstrings}',   '{lower_back,upper_back}','barbell',    'hinge',           false, 5),
  ('Romanian Deadlift',       '{hamstrings,glutes}',   '{lower_back}',           'barbell',    'hinge',           false, 5),
  ('Hip Thrust',              '{glutes}',              '{hamstrings}',           'barbell',    'hinge',           false, 5),
  ('Lying Leg Curl',          '{hamstrings}',          '{}',                     'machine',    'isolation',       false, 2.5),
  ('Leg Extension',           '{quads}',               '{}',                     'machine',    'isolation',       false, 2.5),
  ('Standing Calf Raise',     '{calves}',              '{}',                     'machine',    'isolation',       false, 5),
  ('Bench Press',             '{chest}',               '{triceps,front_delts}',  'barbell',    'horizontal_push', false, 2.5),
  ('Incline Dumbbell Press',  '{chest}',               '{front_delts,triceps}',  'dumbbell',   'horizontal_push', false, 2),
  ('Dip',                     '{chest,triceps}',       '{front_delts}',          'bodyweight', 'vertical_push',   false, 2.5),
  ('Cable Fly',               '{chest}',               '{}',                     'cable',      'isolation',       false, 2.5),
  ('Overhead Press',          '{front_delts}',         '{triceps,side_delts}',   'barbell',    'vertical_push',   false, 2.5),
  ('Dumbbell Lateral Raise',  '{side_delts}',          '{}',                     'dumbbell',   'isolation',       false, 1),
  ('Pull-up',                 '{lats}',                '{biceps,upper_back}',    'bodyweight', 'vertical_pull',   false, 2.5),
  ('Lat Pulldown',            '{lats}',                '{biceps}',               'cable',      'vertical_pull',   false, 2.5),
  ('Barbell Row',             '{upper_back,lats}',     '{biceps,rear_delts}',    'barbell',    'horizontal_pull', false, 2.5),
  ('Chest-Supported Row',     '{upper_back}',          '{lats,rear_delts}',      'machine',    'horizontal_pull', false, 2.5),
  ('Face Pull',               '{rear_delts}',          '{upper_back}',           'cable',      'isolation',       false, 2.5),
  ('Barbell Curl',            '{biceps}',              '{forearms}',             'barbell',    'isolation',       false, 2.5),
  ('Cable Triceps Pushdown',  '{triceps}',             '{}',                     'cable',      'isolation',       false, 2.5),
  ('Hanging Leg Raise',       '{abs}',                 '{hip_flexors}',          'bodyweight', 'core',            false, 2.5);
