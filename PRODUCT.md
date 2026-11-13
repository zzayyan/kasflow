# Product

<!-- impeccable:product-schema 1 -->

## Platform

android

## Users

The owner, using it on their own phone (Galaxy A54) every day. The job: record each expense and income as it happens, then see where the money goes and whether the month is on track. Single user per account; every row belongs to one `user_id`. Family or household features (shared accounts, members) are out of scope and would be a separate app.

Confirmed: the owner is the primary user today. A public Play Store release is planned for later, with no date. Treat other people as a future audience, not a present one.

## Product Purpose

Kasflow is a personal finance app for Android (Flutter). It lets one person capture transactions with little effort, keep accounts, categories, labels, bills, and plans in order, read reports, and get an AI assessment of their finances. Success: the owner records transactions as a habit and trusts the numbers.

## Positioning

Three differences the owner confirmed:

- **Offline-first.** Data lives in on-device SQLite and syncs to Supabase through PowerSync, so the app works without a connection.
- **Capture with AI.** Free-text input, bank and e-wallet notifications, and receipt photos are parsed into transactions (Edge Functions `parse-quick-input`, `parse-transaction`, `parse-receipt`).
- **Diagnosis CFO.** An AI assessment of finances, scored on recorded months and counted accounts only (`diagnose-finance`).

## Operating Context

- Used on a phone, often in one hand and between other apps, for quick entries.
- Rupiah, Indonesian language, Indonesian bank and e-wallet notifications.
- The owner keeps Android's system touch vibration off, so the app plays its own haptics behind a "Getar saat mengetuk" toggle. The app also honors Android's "remove animations" setting.
- Sign-in by email and password, or by Google ("Lanjut dengan Google", shown only when `GOOGLE_WEB_CLIENT_ID` is set). A Google account with the same verified email resolves to the same user.

## Capabilities and Constraints

- Screens in `lib/screens/`: Beranda (dashboard), records, accounts, bills, plans, report, categories, labels, Diagnosis CFO, onboarding, login, Pengaturan.
- Settings: theme, haptics, app lock, hide balance, reminder time, home budget. CSV export. Home widget.
- Android only, phone-sized screens. No web or iOS build is planned.
- UI copy is Indonesian. Code, comments, and commit messages are English.
- Real data on the owner's phone must survive updates: install in place, never uninstall.
- The release build is signed with the debug key today. A store release needs its own signing.

## Brand Commitments

The owner's existing design is binding. `lib/screens/` implements every artboard of the canvas "Cashflow UI/UX", and `lib/theme.dart` holds its tokens (`AppColors`, `AppText`, `AppRadius`, `AppSpace`). New UI matches those screens and tokens. Shared form pieces live in `lib/ui.dart`. The owner notices drift, such as a moved + button. A screen with no artboard needs its design from the owner first.

## Evidence on Hand

- A working app in daily use, with the design canvas as source of truth for the screens.
- No testimonials, other users, or store listing exist. Do not fabricate them.
- The owner's financial data is private. Never copy it into docs or examples.

## Product Principles

1. Recording must cost seconds. Every extra tap on the capture path needs a reason.
2. Offline first: no screen may require a connection to record or read data.
3. AI proposes, the owner confirms. Parsed transactions and advice stay correctable and never overwrite data silently.
4. Numbers must be trustworthy. A score or total counts only what was recorded, and says so.
5. Personal scope. Keep the app a single-user tool; shared-household features belong in a separate app.

## Accessibility & Inclusion

No formal standard is set. Known needs: reduced motion honored, haptics optional, balances can be hidden in public. Public release is planned, so the accessibility target (for example WCAG AA or Android accessibility guidance) is an open decision to settle before the store listing.
