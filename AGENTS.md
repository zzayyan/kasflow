# Agent guide

This file is the single source of truth for every coding agent on this repo (Claude Code, Antigravity, and others). Setup, layout, and test commands are in `README.md`. This file holds what the code does not show. When you learn a lasting convention, gotcha, or decision, add it here, not to an agent's private memory.

## Scope

- Android-only personal finance app. Screens are phone-sized; no web build is planned.
- Personal only: every row belongs to one `user_id`, with per-user RLS and PowerSync streams. Family or household features (shared accounts, members) will be a separate app, so keep them out of this one.

## Design

- The screens in `lib/screens/` implement every artboard of the owner's design, and `lib/theme.dart` holds its tokens (`AppColors`, `AppText`, `AppRadius`, `AppSpace`). To build or change UI, match the existing screens and use these tokens. The owner notices drift, such as a moved + button.
- A screen with no counterpart in the code needs its design first: ask the owner for a screenshot of the artboard.
- The design itself lives in a Claude Design canvas, "Cashflow UI/UX" (https://claude.ai/artifact/GPENb6juXJgm5LJgogX4Xd, direction E "hijau hutan"). Only Claude can open it, through its Artifact tool. The canvas still shows old chart colors; the code's values are the agreed ones (five distinct validated hues plus gray for the category donut, light "need" color `#4F8A66`).
- UI copy is Indonesian. Code, comments, and commit messages are English.

## Device builds

- The owner uses the app daily on their phone (Galaxy A54). After any device check, leave a release build installed. Debug builds stutter (600-800 ms frames), and the owner reads that as lag.
- Use the release commands in `README.md` exactly, with `--split-per-abi`. That build has versionCode 2001; a plain `--release` build has versionCode 1 and fails with `INSTALL_FAILED_VERSION_DOWNGRADE`.
- Always update in place with `adb install -r`. The phone holds the owner's real data, and uninstalling wipes it.
- `adb` is not on PATH. On Windows, call `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`.
- The phone is paired for Wi-Fi debugging. If `adb devices` is empty, run `adb mdns services` to find the current connect port, then `adb connect <ip:port>`. The port changes when Wi-Fi debugging restarts.

## Git

- `main` is linear and the only long-lived branch (GitHub: zzayyan/cashflow-app). Commit on a short feature branch.
- Run `flutter analyze` and `flutter test` before committing. Run the Supabase tests (see `README.md`) only when `supabase/` changes.
- When the owner approves, fast-forward main (`git merge --ff-only <branch>`), `git push origin main`, then delete the branch.
- Commits and PRs carry the owner as the only author. Write the message without AI co-author trailers or "Generated with" lines.
