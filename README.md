# Cashflow

Personal finance app for Android (Flutter). Offline-first: data lives in on-device SQLite and syncs to Supabase through PowerSync.

## Setup

1. Install Flutter and connect an Android phone with USB debugging (`flutter devices` should list it).
2. Connect the backend: run `./scripts/setup-backend.sh` in Git Bash. It walks through Supabase and PowerSync and writes `.env` (template: `.env.example`).
3. Run the app: `flutter run --dart-define-from-file=.env`

Debug builds are JIT-compiled and stutter (a frame can take 600-800 ms), so judge animations and
daily use on a release build:

```sh
flutter build apk --release --split-per-abi --dart-define-from-file=.env
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

The release build is signed with the debug key, so it installs over a debug build and keeps the data.

## Layout

- `lib/` app code: `db.dart` (PowerSync + Supabase connector), `schema.dart` (on-device tables), `money.dart` (amount parsing), `theme.dart` (design tokens), `ui.dart` (shared widgets), `screens/` (one file per screen)
- `supabase/migrations/` database schema, RLS policies, signup trigger
- `powersync/sync-config.yaml` which rows each user downloads

## Checks

- `flutter test`
- `cd supabase/tests && npm install && npm test` runs the migration against PGlite and checks constraints and RLS
- GitHub Actions runs both on every push (`.github/workflows/checks.yml`)
- On the phone, `adb logcat -s flutter` shows the app's log records and uncaught errors, release builds included
