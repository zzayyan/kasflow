import 'package:cashflow_app/screens/plans_tab.dart';
import 'package:cashflow_app/screens/records_tab.dart';
import 'package:cashflow_app/theme.dart';
import 'package:flutter/material.dart';
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

  for (final brightness in Brightness.values) {
    testWidgets('RecordRow marks an expense kept out of budgets ($brightness)', (tester) async {
      Map<String, dynamic> row(int excluded) => {
        'id': 'r$excluded',
        'type': 'expense',
        'amount': 15000000,
        'note': 'Dokter gigi',
        'category_name': 'Kesehatan',
        'account_name': 'BRI',
        'exclude_from_budget': excluded,
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness),
          home: Scaffold(
            body: Column(
              children: [
                RecordRow(row(1), detail: '15.33'),
                RecordRow(row(0), detail: '15.33'),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Kesehatan · di luar budget'), findsOneWidget);
      expect(find.text('Kesehatan'), findsOneWidget); // the counted one says nothing extra
    });
  }
}
