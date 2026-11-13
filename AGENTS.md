# Agent guide

This file is the single source of truth for every coding agent on this repo (Claude Code, Antigravity, and others). Setup, layout, and test commands are in `README.md`. This file holds what the code does not show. When you learn a lasting convention, gotcha, or decision, add it here, not to an agent's private memory.

## Handoff

The owner switches between agents mid-task. `.agents/HANDOFF.md` (gitignored) carries the work in progress from one session to the next, so the next agent picks up without the owner re-explaining.

- Start of a session: read `.agents/HANDOFF.md` if it exists, and treat it as the current task. Claude Code receives it through a SessionStart hook.
- When a session leaves work unfinished, or the owner says "handoff": rewrite the whole file to reflect the current state, with the branch, the goal, what is done, what is next, open decisions and the owner's latest feedback, and the skills the next agent should use. Point at commits, files, and URLs instead of copying them. Keep secrets and the owner's financial data out.
- After the branch merges into main, delete the file.
- In Claude Code, a Stop hook (`.claude/hooks/handoff-stale.sh`) asks for the rewrite whenever files changed after the last one.

## Skills

The owner's skills live in `~/.agents/skills/<name>/SKILL.md`; Claude Code also gets them from the mattpocock-skills plugin. Use the matching skill through your skill tool, or read its `SKILL.md` if your agent has none:

- `diagnosing-bugs`: something broken, throwing, failing, or slow.
- `tdd`: a feature or fix built test-first.
- `prototype`: a throwaway to try a state model or a UI idea.
- `research`: facts from primary sources, written up as Markdown.
- `domain-modeling`: naming domain terms, or writing a glossary or ADR.
- `codebase-design`: a module's interface, seams, or testability.
- `code-review`: reviewing a branch, a PR, or work in progress.
- `resolving-merge-conflicts`: a merge or rebase stopped on conflicts.
- `grilling`: the owner wants a plan stress-tested.
- `writing-for-agents`: editing this file, a skill, or another doc agents read.
- `handoff`: the owner says "handoff". It runs only when the owner invokes it, so an agent's skill list may leave it out; follow the Handoff section either way, saving to `.agents/HANDOFF.md` in place of the OS temp folder.

For a library or SDK question (Flutter, PowerSync, Supabase), look up current docs, through context7 where available, before answering from memory.

## Scope

- Android-only personal finance app. Screens are phone-sized; no web build is planned.
- The app is named Flowku. The Android `applicationId`, the Kotlin package, and the Dart package keep the old `cashflow` names on purpose: a new `applicationId` is a different app to Android, so the owner's phone would lose its data.
- Personal only: every row belongs to one `user_id`, with per-user RLS and PowerSync streams. Family or household features (shared accounts, members) will be a separate app, so keep them out of this one.

## Design

- The screens in `lib/screens/` implement every artboard of the owner's design, and `lib/theme.dart` holds its tokens (`AppColors`, `AppText`, `AppRadius`, `AppSpace`). To build or change UI, match the existing screens and use these tokens. The owner notices drift, such as a moved + button.
- A screen with no counterpart in the code needs its design first: ask the owner for a screenshot of the artboard.
- The design itself lives in a Claude Design canvas, "Cashflow UI/UX" (https://claude.ai/artifact/GPENb6juXJgm5LJgogX4Xd, direction E "hijau hutan"). Only Claude can open it, through its Artifact tool. The canvas still shows old chart colors; the code's values are the agreed ones (five distinct validated hues plus gray for the category donut, light "need" color `#4F8A66`).
- Forms follow the Catat transaksi artboard through shared pieces in `lib/ui.dart`: `FormSheet` for a form in a bottom sheet, `FormCard` and `FormRow` for its fields and pickers, `chooseOne` for a pick list, `SheetTitle` for a menu sheet. A row holding a text field passes the field's `focusNode`, so a tap anywhere on the row types into it.
- Tap feedback goes through `haptic()` in `lib/ui.dart`. The owner keeps Android's system touch vibration off, which silences Flutter's `HapticFeedback`; `haptic()` plays on the vibrator through `MainActivity.kt`, behind the app's own "Getar saat mengetuk" toggle. Every `onLongPress` starts with `haptic(Haptic.click)`, so a hold always answers before its menu or dialog opens.
- Animation durations go through `motion()`, which turns them to zero when Android's "remove animations" setting is on.
- UI copy is Indonesian. Code, comments, and commit messages are English.
- The README images in `docs/readme/` come from `screenshots/readme_test.dart`, which renders the screens from made-up data. After changing a screen that appears in them, rerun `flutter test screenshots --update-goldens`. Never use screenshots from the owner's phone: it holds their real finances.

## Device builds

- The owner uses the app daily on their phone (Galaxy A54). After any device check, leave a release build installed. Debug builds stutter (600-800 ms frames), and the owner reads that as lag.
- Use the release commands in `README.md` exactly, with `--split-per-abi`. That build has versionCode 2001; a plain `--release` build has versionCode 1 and fails with `INSTALL_FAILED_VERSION_DOWNGRADE`.
- Always update in place with `adb install -r`. The phone holds the owner's real data, and uninstalling wipes it.
- The phone is often in the owner's hand, in another app. Before each `adb shell input` tap, take a screenshot and confirm it shows the screen the tap is meant for, not only that Flowku holds focus (`adb shell dumpsys window | grep mCurrentFocus`). A tap aimed at one screen can land on another: on the home screen it opens whatever app sits there, and in Flowku it can reach Profil's Keluar.
- `adb` is not on PATH. On Windows, call `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`.
- The phone is paired for Wi-Fi debugging. If `adb devices` is empty, run `adb mdns services` to find the current connect port, then `adb connect <ip:port>`. The port changes when Wi-Fi debugging restarts.

## Edge Functions

- Deploy one function with `npx supabase functions deploy <name> --remote=<ref> --yes`. The ref is the subdomain of `SUPABASE_URL` in `.env`.
- A deploy goes straight to production, so ask the owner before each one. `--yes` answers the CLI's confirmation, which an agent run cannot answer itself.

## Git

- `main` is linear and the only long-lived branch (GitHub: zzayyan/flowku). Commit on a short feature branch.
- Run `flutter analyze` and `flutter test` before committing. Run the Supabase tests (see `README.md`) only when `supabase/` changes.
- When the owner approves, fast-forward main (`git merge --ff-only <branch>`), `git push origin main`, then delete the branch.
- Commits and PRs carry the owner as the only author. Write the message without AI co-author trailers or "Generated with" lines.
