# Overload

Personal-first gym app: training log, food log, steps and body metrics feeding one loop, with a
deterministic growth engine and an AI coach. Full spec: [docs/PLAN.md](docs/PLAN.md).

**Phase 0 (foundations) is built. Phase 1 (training MVP) is next.**

```
app/                Flutter app (Riverpod, go_router, PowerSync + Drift, Supabase auth)
supabase/           Postgres schema + row-level security migrations
powersync/          Sync Streams config
docs/PLAN.md        The spec: features, growth engine, AI coach, data model, roadmap
```

## What works today

Sign in (Apple, Google, or email and password) → start and finish a workout, on or offline → it syncs to
Postgres when a connection is back. The sync chip in the app bar and Settings show the state and how
many changes are still queued. The Fuel, Progress and Coach tabs name what arrives in later phases.

## Setup

New machine? [req.txt](req.txt) lists the whole toolchain with versions, and
`bash scripts/setup.sh` installs what it can and tells you the rest.

You also need a [Supabase](https://supabase.com) project (free tier) and a
[PowerSync](https://powersync.com) instance (free tier). Roughly 20 minutes.

**1. Supabase project.** Create one, then from Project Settings → API copy the project URL and the
publishable key.

**2. Push the schema.**

```bash
npx supabase login
npx supabase link --project-ref YOUR-PROJECT-REF
npx supabase db push
```

**3. Email sign-in.** In Auth → Providers, enable Email. Then add yourself under
Authentication → Users → **Add user**, with *Auto Confirm User* ticked — that's a working account
with no email delivery involved.

Supabase only lets you edit email templates once custom SMTP is configured, and its built-in sender
is rate-limited to a few messages an hour, so password sign-in is the path of least resistance while
developing. To move to emailed 6-digit codes later, add custom SMTP (Resend's free tier works), put
`{{ .Token }}` in the Magic Link template, and switch `AuthService` back to `signInWithOtp` /
`verifyOTP`. Apple and Google sign-in are independent of all this — see "Native sign-in" below.

**4. PowerSync replication role.** In the Supabase SQL editor, with your own password:

```sql
create role powersync_role with replication bypassrls login password 'YOUR-STRONG-PASSWORD';
grant select on all tables in schema public to powersync_role;
alter default privileges in schema public grant select on tables to powersync_role;
```

The `powersync` publication already exists — the first migration creates it.

**5. PowerSync instance.** Create one, connect it to your Supabase database using the
`powersync_role` credentials, and set client auth to Supabase Auth (it validates the Supabase JWT).
Then paste [powersync/sync-streams.yaml](powersync/sync-streams.yaml) into the instance's Sync
Streams config and deploy. Copy the instance URL.

**6. App config.**

```bash
cp app/config/dev.example.json app/config/dev.json   # then fill in the three URLs/keys
cd app && flutter pub get && dart run build_runner build
flutter run --dart-define-from-file=config/dev.json
```

`config/dev.json` is gitignored. Without it the app opens a screen telling you which values are missing.

## Verifying Phase 0

The exit test from the roadmap:

1. Sign in on your phone.
2. Turn on airplane mode. The chip in the app bar reads **Offline**.
3. Train → **Start workout**, then **Finish workout**. Both work with no connection.
4. Settings shows **Waiting to upload: 2**.
5. Turn airplane mode off. The chip goes **Syncing** → **Synced** and the count drops to 0.
6. In Supabase → Table Editor → `sessions`, your row is there.

## Native sign-in (optional)

- **Apple (iOS):** open `app/ios/Runner.xcworkspace` in Xcode → Signing & Capabilities → add
  *Sign in with Apple*. Then enable the Apple provider in Supabase Auth with your Service ID.
- **Google:** create OAuth clients in Google Cloud (iOS + Web), put the web client ID in Supabase's
  Google provider, and add both IDs to `config/dev.json`. On iOS also add the reversed iOS client ID
  as a URL scheme in `ios/Runner/Info.plist`. If iOS sign-in fails with a nonce mismatch, turn on
  "Skip nonce checks" in Supabase's Google provider settings.

The app hides the Apple button off iOS and the Google button until its client IDs are configured.

- **`USDA_API_KEY`** is optional, free from
  [fdc.nal.usda.gov/api-key-signup.html](https://fdc.nal.usda.gov/api-key-signup.html). It adds USDA
  FoodData Central to the food search, which is where raw ingredients live — "chicken breast, raw",
  "white rice, dry", the things a recipe is made of. Open Food Facts covers packaged food and needs
  no key. Without a USDA key that half of the search is simply absent: no error, nothing to explain.

## Development

From `app/`:

```bash
dart run build_runner build    # after changing Drift tables
flutter analyze && flutter test
```

CI runs the same, plus applies every migration to a throwaway Postgres.

## Build tooling on this machine

`flutter doctor` currently reports two gaps, so neither platform can be built here yet:

- **iOS:** needs full Xcode (`xcode-select --switch /Applications/Xcode.app/Contents/Developer`) and
  CocoaPods.
- **Android:** needs the `cmdline-tools` component and `flutter doctor --android-licenses`.

Distribution to TestFlight and Play internal testing is not wired up yet: it needs an Apple Developer
account, an App Store Connect API key and a Play service account.
