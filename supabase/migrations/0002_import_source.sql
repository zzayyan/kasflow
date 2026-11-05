-- Records brought in from another app's export (the Wallet / BudgetBakers history).
-- source_ref holds 'wallet|<row>' so running the same import twice adds nothing.
alter table records drop constraint records_source_check;
alter table records add constraint records_source_check
  check (source in ('manual', 'notification', 'nlp', 'planned', 'import'));
