import 'package:cashflow_app/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('accountBalancesSql: opening balance plus confirmed records, transfers on both sides', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute('''
      CREATE TABLE accounts (id TEXT, initial_balance INTEGER);
      CREATE TABLE records (account_id TEXT, type TEXT, amount INTEGER, transfer_account_id TEXT,
        transfer_amount INTEGER, status TEXT);
      INSERT INTO accounts VALUES ('cash', 1000), ('bank', 500), ('unused', 70);
      INSERT INTO records VALUES
        ('cash', 'income', 300, NULL, NULL, 'confirmed'),
        ('cash', 'expense', 100, NULL, NULL, 'confirmed'),
        ('cash', 'transfer', 200, 'bank', 200, 'confirmed'),
        ('cash', 'transfer', 150, 'bank', 90, 'confirmed'), -- received less: another currency
        ('bank', 'expense', 50, NULL, NULL, 'pending'), -- not confirmed: not counted
        ('bank', 'transfer', 40, 'bank', 40, 'confirmed'); -- onto itself: only leaves, never doubles
    ''');
    final balances = {for (final r in db.select(accountBalancesSql)) r['id']: r['balance']};
    expect(balances, {'cash': 850, 'bank': 750, 'unused': 70});
  });
}
