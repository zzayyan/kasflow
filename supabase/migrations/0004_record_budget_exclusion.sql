-- A one-off expense the user keeps out of their budgets, such as a doctor's visit or a repair.
-- It still counts in Laporan, Diagnosis and the account balance: only budget spending skips it.
alter table records add column exclude_from_budget boolean not null default false;
