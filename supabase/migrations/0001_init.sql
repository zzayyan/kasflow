-- Cashflow app MVP schema (Supabase Postgres, synced to on-device SQLite via PowerSync).
-- Money is stored as bigint minor units (e.g. Rp 25.000 = 2500000 with exponent 2) to avoid float errors.
-- Balances and budget spending are never stored: they are computed from records, so there is nothing to conflict on during sync.

-- Every synced table has an `id` primary key because PowerSync requires one.
create table user_settings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique default auth.uid() references auth.users on delete cascade,
  base_currency char(3) not null default 'IDR',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  name text not null,
  type text not null check (type in ('cash','bank','ewallet','paylater','credit_card','savings','investment','loan')),
  provider text,                      -- preset key such as 'gopay', 'dana', 'bca'; the preset list lives in app code
  currency char(3) not null default 'IDR',
  initial_balance bigint not null default 0,
  color text,
  archived boolean not null default false,
  exclude_from_stats boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table categories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  parent_id uuid references categories on delete cascade,
  name text not null,
  type text not null check (type in ('income','expense')),
  need_level text check (need_level in ('must','need','want')),
  keywords jsonb not null default '[]',  -- used by natural-language input to guess the category ("bakso" -> Makan)
  color text,
  icon text,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table labels (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  name text not null,
  color text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  account_id uuid not null references accounts on delete cascade,
  type text not null check (type in ('income','expense','transfer')),
  amount bigint not null check (amount > 0),       -- always positive; type decides the sign
  currency char(3) not null,
  category_id uuid references categories on delete set null,
  transfer_account_id uuid references accounts on delete cascade,
  transfer_amount bigint,                          -- amount received, differs from amount for cross-currency transfers
  label_ids jsonb not null default '[]',
  note text,
  payee text,
  place text,
  photo_path text,                                 -- Supabase Storage object path
  occurred_at timestamptz not null default now(),
  status text not null default 'confirmed' check (status in ('confirmed','pending')),  -- 'pending' = auto-captured, waiting for user review
  source text not null default 'manual' check (source in ('manual','notification','nlp','planned')),
  source_ref text,                                 -- dedupe key for auto-captured notifications
  planned_payment_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((type = 'transfer') = (transfer_account_id is not null))
);
create unique index records_source_ref_key on records (user_id, source_ref) where source_ref is not null;
create index records_user_time on records (user_id, occurred_at desc);

create table budgets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  name text not null,
  period text not null check (period in ('week','month','year','custom')),
  amount bigint not null check (amount > 0),
  currency char(3) not null default 'IDR',
  start_date date not null,
  end_date date,                                   -- only for 'custom'
  -- ponytail: filters are JSON id arrays, not join tables; deleting a category leaves a dangling id that the app ignores. Move to join tables if that becomes a problem.
  category_ids jsonb not null default '[]',        -- empty = all expense categories
  account_ids jsonb not null default '[]',         -- empty = all accounts
  label_ids jsonb not null default '[]',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table goals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  name text not null,
  target_amount bigint not null check (target_amount > 0),
  currency char(3) not null default 'IDR',
  account_id uuid references accounts on delete set null,  -- progress = balance of this account
  target_date date,
  state text not null default 'active' check (state in ('active','paused','reached')),
  color text,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table planned_payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  name text not null,
  account_id uuid not null references accounts on delete cascade,
  category_id uuid references categories on delete set null,
  type text not null check (type in ('income','expense')),
  amount bigint not null check (amount > 0),
  currency char(3) not null default 'IDR',
  rrule text not null,                             -- RFC 5545, e.g. 'FREQ=MONTHLY;BYMONTHDAY=25'
  next_due_date date not null,
  remind_days_before int not null default 1 check (remind_days_before in (0,1,3,7)),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table records add foreign key (planned_payment_id) references planned_payments on delete set null;

-- Global daily rates, readable by everyone, written by a scheduled job.
-- ponytail: no job yet; the app falls back to a manual rate. Add a daily Edge Function cron when multi-currency is used.
create table exchange_rates (
  id uuid primary key default gen_random_uuid(),
  rate_date date not null,
  currency char(3) not null,
  per_usd numeric not null check (per_usd > 0),
  unique (rate_date, currency)
);

-- Row level security: every user sees and writes only their own rows.
alter table user_settings enable row level security;
alter table accounts enable row level security;
alter table categories enable row level security;
alter table labels enable row level security;
alter table records enable row level security;
alter table budgets enable row level security;
alter table goals enable row level security;
alter table planned_payments enable row level security;
alter table exchange_rates enable row level security;

create policy own_rows on user_settings for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy own_rows on accounts for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy own_rows on categories for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy own_rows on labels for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy own_rows on records for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy own_rows on budgets for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy own_rows on goals for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy own_rows on planned_payments for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy read_all on exchange_rates for select to authenticated using (true);

-- New user: create settings and default categories on the server, so two devices
-- logging in for the first time while offline cannot create duplicate defaults.
create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into user_settings (user_id) values (new.id);
  insert into categories (user_id, name, type, need_level, keywords) values
    (new.id, 'Makan & Minum', 'expense', 'need', '["makan","minum","bakso","kopi","nasi","jajan","gofood","grabfood"]'),
    (new.id, 'Belanja Harian', 'expense', 'need', '["belanja","indomaret","alfamart","pasar","sayur"]'),
    (new.id, 'Transportasi', 'expense', 'need', '["bensin","parkir","tol","gojek","grab","ojek","krl","mrt"]'),
    (new.id, 'Tagihan', 'expense', 'must', '["listrik","pln","air","pdam","internet","wifi","pulsa","token"]'),
    (new.id, 'Tempat Tinggal', 'expense', 'must', '["kos","kost","sewa","kontrakan","kpr"]'),
    (new.id, 'Kesehatan', 'expense', 'must', '["obat","dokter","apotek","bpjs","klinik"]'),
    (new.id, 'Hiburan', 'expense', 'want', '["nonton","bioskop","game","netflix","spotify","langganan"]'),
    (new.id, 'Belanja Online', 'expense', 'want', '["shopee","tokopedia","lazada","tiktok shop"]'),
    (new.id, 'Pendidikan', 'expense', 'need', '["kursus","buku","sekolah","kuliah"]'),
    (new.id, 'Sedekah & Hadiah', 'expense', 'need', '["sedekah","infaq","zakat","kado","hadiah"]'),
    (new.id, 'Lainnya', 'expense', null, '[]'),
    (new.id, 'Gaji', 'income', null, '["gaji","salary","thr","bonus"]'),
    (new.id, 'Pemasukan Lain', 'income', null, '["transfer masuk","refund","cashback"]');
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- PowerSync reads changes through logical replication.
create publication powersync for table
  user_settings, accounts, categories, labels, records, budgets, goals, planned_payments, exchange_rates;
