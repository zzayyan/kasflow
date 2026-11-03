# Cashflow

Personal finance app for Android (Flutter). Offline-first: data lives in on-device SQLite and syncs to Supabase through PowerSync.

## Setup

1. Install Flutter and connect an Android phone with USB debugging (`flutter devices` should list it).
2. Connect the backend: run `./scripts/setup-backend.sh` in Git Bash. It walks through Supabase and PowerSync and writes `.env` (template: `.env.example`).
3. Run the app: `flutter run --dart-define-from-file=.env`

## Layout

- `lib/` app code: `db.dart` (PowerSync + Supabase connector), `schema.dart` (on-device tables), `money.dart` (amount parsing), `main.dart` (UI)
- `supabase/migrations/` database schema, RLS policies, signup trigger
- `powersync/sync-config.yaml` which rows each user downloads

## Checks

- `flutter test`
- `cd supabase/tests && npm install && npm test` runs the migration against PGlite and checks constraints and RLS
