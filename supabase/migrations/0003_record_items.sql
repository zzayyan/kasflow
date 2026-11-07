-- The lines of a scanned receipt, kept on its record so they show in the form and match a search.
-- [{"name": "Teh Tarik Dingin", "qty": 1, "amount": 3300000}, ...]: amount is the line total in
-- minor units (x100), like records.amount. Null for records without a receipt.
alter table records add column items jsonb
  check (items is null or jsonb_typeof(items) = 'array');
