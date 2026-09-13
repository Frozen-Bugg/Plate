/// Everything the coach can read, and the one place that talks to Postgres.
///
/// An interface rather than direct queries, for the same reason the model is
/// one: the tools and the snapshot are tested against an in-memory fake, with
/// no database, no network and no seeded project.
///
/// Every query selects named columns. `select=*` would pull ids and the user id
/// into a payload bound for a model — see `privacy.ts`, which is what catches
/// that if it ever happens.

/// One day, already aggregated. The snapshot is built almost entirely from
/// these: `daily_rollup` is one row per day by design, which is exactly the
/// shape a coach should be reasoning from.
export interface Day {
  day: string;
  trendWeightKg?: number;
  weightKg?: number;
  steps?: number;
  sleepMinutes?: number;
  readiness?: number;
  hardSets?: number;
  volumeKg?: number;
  intakeKcal?: number;
  proteinG?: number;
  tdeeEst?: number;
  phase?: string;
}

/// The lifter, with nothing that identifies them.
export interface Profile {
  experience?: string;
  phase?: string;
  heightCm?: number;
  birthYear?: number;
  sex?: string;
  equipment?: string[];
  /// Free text the lifter wrote. Passed through because a coach that cannot see
  /// "left shoulder, no overhead press" is a coach that will prescribe one.
  injuries?: string;
}

export interface Target {
  from: string;
  kcal: number;
  proteinG: number;
  carbG: number;
  fatG: number;
  source: string;
  tdeeKcal?: number;
}

/// What the engine decided for one exercise. Named, never identified.
export interface Progression {
  exercise: string;
  nextLoadKg?: number;
  nextReps?: number;
  stallCount?: number;
  bestE1rmKg?: number;
  /// When the engine last rewrote this verdict — it does so when a session
  /// finishes, so it doubles as "last trained". There is no column that says so
  /// outright.
  reconsideredOn?: string;
}

/// One finished session, summarised.
export interface Session {
  day: string;
  minutes?: number;
  exercises: string[];
  sets: number;
  volumeKg: number;
  prs: number;
}

/// Sets for one exercise, for the questions a summary cannot answer.
export interface SetRow {
  day: string;
  exercise: string;
  weightKg?: number;
  reps?: number;
  rir?: number;
  e1rmKg?: number;
  isPr: boolean;
}

/// What was eaten on a day, by meal.
export interface MealRow {
  day: string;
  slot: string;
  food: string;
  quantityG: number;
  kcal: number;
  proteinG: number;
  carbG: number;
  fatG: number;
}

/// Hard sets and volume per muscle, for the "am I doing enough back work"
/// question. Muscles come from the exercise library, so it is only as good as
/// the library's tagging — which is why the tool that returns this says so.
export interface MuscleVolume {
  muscle: string;
  hardSets: number;
  volumeKg: number;
}

/// A note the coach kept. Content only: which thread it came from is a row id.
export interface Memory {
  content: string;
  kind: string;
  weight: number;
}

export interface CoachData {
  profile(): Promise<Profile | null>;
  /// Aggregated days, newest first, from [since] inclusive.
  days(since: string): Promise<Day[]>;
  targetOn(day: string): Promise<Target | null>;
  progression(): Promise<Progression[]>;
  sessions(since: string): Promise<Session[]>;
  setsFor(exercise: string, since: string): Promise<SetRow[]>;
  meals(since: string): Promise<MealRow[]>;
  /// Names only — the coach picks a movement by name and the server resolves it.
  exerciseNames(): Promise<string[]>;
  volumeByMuscle(since: string): Promise<MuscleVolume[]>;
  foodNames(match: string): Promise<string[]>;
  memories(): Promise<Memory[]>;
}

/// Reads through PostgREST as the signed-in lifter.
///
/// The user's own JWT is forwarded, so RLS is what scopes every query — the
/// same policies the app is subject to. Nothing here filters by user id,
/// because nothing here is trusted to.
export class SupabaseData implements CoachData {
  readonly #url: string;
  readonly #anonKey: string;
  readonly #jwt: string;
  readonly #fetch: typeof fetch;

  constructor(
    url: string,
    anonKey: string,
    userJwt: string,
    fetchImpl: typeof fetch = fetch,
  ) {
    this.#url = url.replace(/\/$/, '');
    this.#anonKey = anonKey;
    this.#jwt = userJwt;
    this.#fetch = fetchImpl;
  }

  async #get<T>(path: string): Promise<T[]> {
    const response = await this.#fetch(`${this.#url}/rest/v1/${path}`, {
      headers: {
        apikey: this.#anonKey,
        // RLS applies to this token, not to the service role. A service-role
        // key here would give the coach every lifter's data and rely on a
        // WHERE clause to be careful, which is not a security model.
        Authorization: `Bearer ${this.#jwt}`,
        Accept: 'application/json',
      },
    });
    if (!response.ok) {
      const detail = await response.text().catch(() => '');
      throw new Error(
        `Could not read ${path.split('?')[0]}: ${response.status} ${detail.slice(0, 200)}`,
      );
    }
    return (await response.json()) as T[];
  }

  async profile(): Promise<Profile | null> {
    const rows = await this.#get<Record<string, unknown>>(
      'profiles?select=experience,phase,height_cm,birth_year,sex,equipment,injuries&limit=1',
    );
    const row = rows[0];
    if (!row) return null;
    return {
      experience: str(row.experience),
      phase: str(row.phase),
      heightCm: num(row.height_cm),
      birthYear: num(row.birth_year),
      sex: str(row.sex),
      equipment: Array.isArray(row.equipment) ? row.equipment.map(String) : undefined,
      injuries: str(row.injuries),
    };
  }

  async days(since: string): Promise<Day[]> {
    const rows = await this.#get<Record<string, unknown>>(
      'daily_rollup?select=rollup_on,trend_weight_kg,weight_kg,steps,sleep_minutes,' +
        'readiness,hard_sets,volume_kg,intake_kcal,protein_g,tdee_est,phase' +
        `&rollup_on=gte.${since}&deleted_at=is.null&order=rollup_on.desc`,
    );
    return rows.map((row) => ({
      day: String(row.rollup_on),
      trendWeightKg: num(row.trend_weight_kg),
      weightKg: num(row.weight_kg),
      steps: num(row.steps),
      sleepMinutes: num(row.sleep_minutes),
      readiness: num(row.readiness),
      hardSets: num(row.hard_sets),
      volumeKg: num(row.volume_kg),
      intakeKcal: num(row.intake_kcal),
      proteinG: num(row.protein_g),
      tdeeEst: num(row.tdee_est),
      phase: str(row.phase),
    }));
  }

  async targetOn(day: string): Promise<Target | null> {
    // Effective-dated: the live target is the newest row that has started.
    const rows = await this.#get<Record<string, unknown>>(
      'nutrition_targets?select=effective_from,kcal,protein_g,carb_g,fat_g,source,tdee_kcal' +
        `&effective_from=lte.${day}&deleted_at=is.null` +
        '&order=effective_from.desc&limit=1',
    );
    const row = rows[0];
    if (!row) return null;
    return {
      from: String(row.effective_from),
      kcal: num(row.kcal) ?? 0,
      proteinG: num(row.protein_g) ?? 0,
      carbG: num(row.carb_g) ?? 0,
      fatG: num(row.fat_g) ?? 0,
      source: str(row.source) ?? 'engine',
      tdeeKcal: num(row.tdee_kcal),
    };
  }

  async progression(): Promise<Progression[]> {
    const rows = await this.#get<Record<string, any>>(
      'progression_state?select=next_load_kg,next_reps,stall_count,best_e1rm_kg,' +
        'updated_at,exercises(name)&deleted_at=is.null',
    );
    return rows
      .map((row) => ({
        exercise: str(row.exercises?.name) ?? '',
        nextLoadKg: num(row.next_load_kg),
        nextReps: num(row.next_reps),
        stallCount: num(row.stall_count),
        bestE1rmKg: num(row.best_e1rm_kg),
        reconsideredOn: str(row.updated_at)?.slice(0, 10),
      }))
      .filter((row) => row.exercise !== '');
  }

  async sessions(since: string): Promise<Session[]> {
    const rows = await this.#get<Record<string, any>>(
      'sessions?select=started_at,ended_at,session_exercises(exercises(name),' +
        'sets(weight_kg,reps,is_pr,deleted_at))' +
        `&started_at=gte.${since}&ended_at=not.is.null&deleted_at=is.null` +
        '&order=started_at.desc',
    );
    return rows.map((row) => {
      const exercises: string[] = [];
      let sets = 0;
      let volumeKg = 0;
      let prs = 0;

      for (const entry of row.session_exercises ?? []) {
        const name = str(entry.exercises?.name);
        if (name) exercises.push(name);
        for (const set of entry.sets ?? []) {
          if (set.deleted_at) continue;
          sets++;
          volumeKg += (num(set.weight_kg) ?? 0) * (num(set.reps) ?? 0);
          if (set.is_pr) prs++;
        }
      }

      const started = new Date(String(row.started_at));
      const ended = row.ended_at ? new Date(String(row.ended_at)) : undefined;
      return {
        day: started.toISOString().slice(0, 10),
        minutes: ended
          ? Math.round((ended.getTime() - started.getTime()) / 60000)
          : undefined,
        exercises,
        sets,
        volumeKg: Math.round(volumeKg),
        prs,
      };
    });
  }

  async setsFor(exercise: string, since: string): Promise<SetRow[]> {
    const rows = await this.#get<Record<string, any>>(
      'sets?select=weight_kg,reps,rir,e1rm_kg,is_pr,logged_at,' +
        'session_exercises!inner(exercises!inner(name))' +
        `&session_exercises.exercises.name=ilike.${encodeURIComponent(exercise)}` +
        `&logged_at=gte.${since}&deleted_at=is.null&order=logged_at.asc`,
    );
    return rows.map((row) => ({
      day: String(row.logged_at).slice(0, 10),
      exercise: str(row.session_exercises?.exercises?.name) ?? exercise,
      weightKg: num(row.weight_kg),
      reps: num(row.reps),
      rir: num(row.rir),
      e1rmKg: num(row.e1rm_kg),
      isPr: row.is_pr === true,
    }));
  }

  async meals(since: string): Promise<MealRow[]> {
    const rows = await this.#get<Record<string, any>>(
      'meal_items?select=quantity_g,kcal,protein_g,carb_g,fat_g,' +
        'foods(name),meals!inner(meal_on,slot)' +
        `&meals.meal_on=gte.${since}&deleted_at=is.null`,
    );
    return rows.map((row) => ({
      day: String(row.meals?.meal_on ?? ''),
      slot: str(row.meals?.slot) ?? 'snack',
      food: str(row.foods?.name) ?? 'Food',
      quantityG: num(row.quantity_g) ?? 0,
      kcal: num(row.kcal) ?? 0,
      proteinG: num(row.protein_g) ?? 0,
      carbG: num(row.carb_g) ?? 0,
      fatG: num(row.fat_g) ?? 0,
    }));
  }

  async exerciseNames(): Promise<string[]> {
    const rows = await this.#get<Record<string, unknown>>(
      'exercises?select=name&deleted_at=is.null&order=name.asc',
    );
    return rows.map((row) => String(row.name));
  }

  async volumeByMuscle(since: string): Promise<MuscleVolume[]> {
    const rows = await this.#get<Record<string, any>>(
      'sets?select=weight_kg,reps,logged_at,kind,' +
        'session_exercises!inner(exercises!inner(primary_muscles))' +
        `&logged_at=gte.${since}&deleted_at=is.null`,
    );

    const totals = new Map<string, MuscleVolume>();
    for (const row of rows) {
      // Warm-ups are not stimulus. Rows written before `kind` was set
      // explicitly have none, and they were all working sets.
      if (row.kind && row.kind !== 'working') continue;
      const muscles: string[] =
        row.session_exercises?.exercises?.primary_muscles ?? [];
      const reps = num(row.reps) ?? 0;
      const volume = (num(row.weight_kg) ?? 0) * reps;
      if (reps <= 0) continue;

      for (const muscle of muscles.length ? muscles : ['untagged']) {
        const current =
          totals.get(muscle) ?? { muscle, hardSets: 0, volumeKg: 0 };
        // A set counts once per muscle it trains; volume is attributed whole to
        // each, so these columns do not sum to the session total. The tool says
        // so rather than leaving the model to assume otherwise.
        current.hardSets += 1;
        current.volumeKg += volume;
        totals.set(muscle, current);
      }
    }

    return [...totals.values()]
      .map((m) => ({ ...m, volumeKg: Math.round(m.volumeKg) }))
      .sort((a, b) => b.hardSets - a.hardSets);
  }

  async foodNames(match: string): Promise<string[]> {
    const safe = encodeURIComponent(`%${match.replace(/[%,()]/g, '')}%`);
    const rows = await this.#get<Record<string, unknown>>(
      `foods?select=name,brand&name=ilike.${safe}&deleted_at=is.null` +
        '&order=last_used_at.desc.nullslast&limit=25',
    );
    return rows.map((row) =>
      [row.name, row.brand].filter(Boolean).join(' · '),
    );
  }

  async memories(): Promise<Memory[]> {
    const rows = await this.#get<Record<string, unknown>>(
      'coach_memories?select=content,kind,weight&deleted_at=is.null' +
        '&order=weight.desc,last_used_at.desc.nullslast&limit=30',
    );
    return rows.map((row) => ({
      content: String(row.content),
      kind: str(row.kind) ?? 'note',
      weight: num(row.weight) ?? 1,
    }));
  }
}

function num(value: unknown): number | undefined {
  if (value === null || value === undefined || value === '') return undefined;
  const n = Number(value);
  return Number.isFinite(n) ? n : undefined;
}

function str(value: unknown): string | undefined {
  if (value === null || value === undefined) return undefined;
  const s = String(value).trim();
  return s === '' ? undefined : s;
}
