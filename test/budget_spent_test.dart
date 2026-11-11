import 'package:cashflow_app/screens/plans_tab.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('budgetSpentSql: an expense kept out of budgets is not counted', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute('''
      CREATE TABLE accounts (id TEXT, exclude_from_stats INTEGER);
      CREATE TABLE records (id TEXT, account_id TEXT, type TEXT, amount INTEGER, status TEXT,
        occurred_at TEXT, category_id TEXT, label_ids TEXT, exclude_from_budget INTEGER);
      INSERT INTO accounts VALUES ('cash', 0);
      INSERT INTO records VALUES
        ('food', 'cash', 'expense', 100, 'confirmed', '2026-11-05T10:00:00Z', NULL, '[]', 0),
        ('doctor', 'cash', 'expense', 900, 'confirmed', '2026-11-06T10:00:00Z', NULL, '[]', 1),
        ('synced', 'cash', 'expense', 50, 'confirmed', '2026-11-07T10:00:00Z', NULL, '[]', NULL);
    ''');
    final spent = db.select(budgetSpentSql, ['2026-11-01', '2026-12-01', '[]', '[]', '[]']).first['spent'];
    expect(spent, 150); // the doctor's visit stays out; a row from before the column counts
  });
}
