# Flowku

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

## Google sign-in (optional)

"Lanjut dengan Google" appears only when `GOOGLE_WEB_CLIENT_ID` is set in `.env`. Setup is outside the repo:

1. Google Cloud Console: create a **Web** OAuth client (its id goes in `.env`) and an **Android** client with package `com.cashflowapp.cashflow_app` and the SHA-1 of the debug keystore (`keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android`). Release builds use the same key, so one Android client covers both; another machine has another SHA-1.
2. Supabase Dashboard, Authentication, Providers, Google: enable it with the Web client id and secret. Turn on "Skip nonce check" if sign-in fails with a nonce error. Keep automatic identity linking on, so a Google account with the same verified email as an email account resolves to the same user.

## Layout

- `lib/` app code: `db.dart` (PowerSync + Supabase connector), `schema.dart` (on-device tables), `money.dart` (amount parsing), `theme.dart` (design tokens), `ui.dart` (shared widgets), `screens/` (one file per screen)
- `supabase/migrations/` database schema, RLS policies, signup trigger
- `powersync/sync-config.yaml` which rows each user downloads

## Checks

- `flutter test`
- `cd supabase/tests && npm install && npm test` runs the migration against PGlite and checks constraints and RLS
- GitHub Actions runs both on every push (`.github/workflows/checks.yml`)
- On the phone, `adb logcat -s flutter` shows the app's log records and uncaught errors, release builds included
