-- Phase 4 (Coach v1): the conversation, what the coach remembers, and the
-- changes it is allowed to suggest but never to make.
--
--   coach_threads    → coach_messages   a conversation and its turns
--   coach_memories                      notes the coach keeps between threads
--   ai_proposals                        a change waiting for the lifter's answer
--
-- Three decisions worth reading before changing anything.
--
-- **The coach never writes to a training or nutrition table.** Everything it
-- wants to change goes into `ai_proposals`, is validated by the engine, and is
-- applied on the device only after the lifter accepts (docs/PLAN.md §7). That
-- is why there is no coach-owned foreign key into `templates`, `sets` or
-- `nutrition_targets`: the proposal carries a payload describing the change,
-- and the engine — not this schema, and not the model — decides whether it is
-- allowed. A declined proposal keeps its reason, because why a lifter said no
-- is the most useful thing the coach can learn in a week.
--
-- **Messages store what was shown, not what was sent.** `content` is the text
-- the lifter saw and `tool_calls` is the chips rendered beside it, not the raw
-- API transcript. Re-running a thread through a newer prompt must not rewrite
-- what the coach said in March, and a transcript full of tool JSON is not
-- something a phone should sync. The API rebuilds its own context each turn
-- from the snapshot and these messages.
--
-- **Memories have no embedding column yet.** docs/PLAN.md §7 retrieves them
-- through pgvector, and that is still the plan — but Anthropic has no
-- embeddings API, so it means a second provider, a second key and a second
-- bill, to do semantic search over notes that do not exist yet. Until then
-- retrieval is recency plus full-text search over `content`, which is the right
-- answer for the first few hundred notes anyway. Adding `embedding vector(n)`
-- later is one `alter table`, and deferring it avoids guessing `n` before the
-- provider is chosen.

-- ---------------------------------------------------------------------------
-- coach_threads
-- ---------------------------------------------------------------------------
--
-- A conversation. `kind` records what opened it, because a Sunday review and a
-- mid-workout "swap this exercise" are not the same thing to look back through,
-- and the API picks a different effort budget for each.

create table public.coach_threads (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,

  -- Written by the coach from the first exchange. Null until then.
  title           text check (title is null or length(title) between 1 and 200),

  kind            text not null default 'chat'
                  check (kind in ('chat', 'brief', 'debrief', 'review', 'nudge')),

  -- Denormalised so the thread list sorts without touching the messages.
  last_message_at timestamptz,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  unique (id, user_id)
);

create index coach_threads_user_recent_idx
  on public.coach_threads (user_id, last_message_at desc nulls last);

-- ---------------------------------------------------------------------------
-- coach_messages
-- ---------------------------------------------------------------------------

create table public.coach_messages (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  thread_id      uuid not null,

  -- Ordering within the thread. created_at is not enough: a turn and its reply
  -- can land in the same millisecond, and the device generates both ids.
  position       integer not null check (position >= 0),

  role           text not null check (role in ('user', 'assistant')),
  content        text not null default '',

  -- What the coach looked at, for the chips under the message: an array of
  -- {tool, summary} objects. Listed in upload_mapping.dart — PowerSync stores
  -- jsonb as text and Postgres would otherwise take the JSON string whole.
  tool_calls     jsonb not null default '[]'::jsonb,

  -- From response.usage, so real spend can be measured rather than estimated
  -- (docs/PLAN.md §7). Null on user turns.
  model          text,
  input_tokens   integer check (input_tokens >= 0),
  output_tokens  integer check (output_tokens >= 0),

  -- A turn that failed is kept and shown, not silently dropped. A coach that
  -- answers nothing and says nothing about it is the same bug as a silently
  -- discarded write.
  error          text,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  unique (id, user_id),
  foreign key (thread_id, user_id)
    references public.coach_threads (id, user_id) on delete cascade
);

create unique index coach_messages_thread_position
  on public.coach_messages (thread_id, position)
  where deleted_at is null;

create index coach_messages_thread_idx
  on public.coach_messages (thread_id, position);

-- ---------------------------------------------------------------------------
-- coach_memories
-- ---------------------------------------------------------------------------
--
-- What the coach carries between conversations: that your left shoulder
-- complains on overhead press, that you travel every third week, that you
-- declined a deload in March and why.
--
-- Written through the `remember` tool and visible to the lifter, because a
-- coach whose notes you cannot read or delete is one you cannot correct.

create table public.coach_memories (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users (id) on delete cascade,

  content      text not null check (length(content) between 1 and 2000),

  kind         text not null default 'note'
               check (kind in ('note', 'preference', 'constraint', 'goal', 'decline')),

  -- How strongly it should outrank others when context is tight.
  weight       smallint not null default 1 check (weight between 1 and 5),

  -- Where it came from, for the memories screen and for undo.
  source       text not null default 'coach'
               check (source in ('coach', 'lifter', 'engine')),
  thread_id    uuid,

  -- Bumped when it is pulled into a turn, so stale notes can be found later.
  last_used_at timestamptz,

  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  unique (id, user_id),
  -- SET NULL names the column: without it Postgres nulls every column in the
  -- key, user_id included, and that column is NOT NULL.
  foreign key (thread_id, user_id)
    references public.coach_threads (id, user_id) on delete set null (thread_id)
);

create index coach_memories_user_idx
  on public.coach_memories (user_id, last_used_at desc nulls last);

-- Retrieval until there is an embedding provider. English-only for now, which
-- matches the coach's prompt.
create index coach_memories_search_idx
  on public.coach_memories using gin (to_tsvector('english', content));

-- ---------------------------------------------------------------------------
-- ai_proposals
-- ---------------------------------------------------------------------------
--
-- The only route from the coach to a change. Nothing here is applied by being
-- written; it is applied by the device, through the engine, after an accept.

create table public.ai_proposals (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null default auth.uid() references auth.users (id) on delete cascade,

  kind             text not null
                   check (kind in ('program_change', 'deload', 'targets',
                                   'meal_plan', 'exercise_swap')),

  status           text not null default 'pending'
                   check (status in ('pending', 'accepted', 'declined',
                                     'expired', 'superseded')),

  -- The change itself, shaped by `kind`. Deliberately not normalised into
  -- columns: each kind carries different fields, and the engine that validates
  -- and applies it owns that shape. Listed in upload_mapping.dart.
  payload          jsonb not null,

  -- What the card says, in the coach's words.
  rationale        text not null default '',

  thread_id        uuid,

  -- The engine's verdict, written before the card is ever shown. A proposal
  -- that has not been validated must not be offered: the MRV ceiling, the
  -- calorie floor and the load-jump limit are the guardrails in
  -- docs/PLAN.md §11, and the model is not trusted to respect them.
  validated        boolean not null default false,
  validation_notes text,

  -- The lifter's answer.
  responded_at     timestamptz,
  decline_reason   text,

  -- A stale proposal is worse than none: the data it was built on has moved on.
  expires_at       timestamptz,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz,
  unique (id, user_id),
  -- SET NULL names the column: without it Postgres nulls every column in the
  -- key, user_id included, and that column is NOT NULL.
  foreign key (thread_id, user_id)
    references public.coach_threads (id, user_id) on delete set null (thread_id),

  -- An answered proposal records when it was answered, and an unanswered one
  -- must not pretend to have been. This is the invariant the proposals inbox
  -- reads, so it is enforced here rather than trusted to the writer.
  check ((status in ('pending', 'expired', 'superseded')) = (responded_at is null)),

  -- A reason belongs to a decline.
  check (decline_reason is null or status = 'declined')
);

create index ai_proposals_user_pending_idx
  on public.ai_proposals (user_id, created_at desc)
  where status = 'pending' and deleted_at is null;

-- ---------------------------------------------------------------------------
-- updated_at, RLS, grants, replication
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array['coach_threads', 'coach_messages', 'coach_memories',
                           'ai_proposals']
  loop
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.set_updated_at()',
      t || '_set_updated_at', t);
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for all to authenticated '
      'using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)',
      t || ': owner only', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('alter publication powersync add table public.%I', t);
  end loop;
end;
$$;
