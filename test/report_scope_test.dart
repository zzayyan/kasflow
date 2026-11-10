import 'package:cashflow_app/screens/report_tab.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('accountScope: all accounts hides the excluded one, picking an account shows it', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute('''
      CREATE TABLE accounts (id TEXT, exclude_from_stats INTEGER);
      CREATE TABLE records (id TEXT, account_id TEXT, amount INTEGER);
      INSERT INTO accounts VALUES ('cash', 0), ('bank', 0), ('side', 1); -- side: "Tidak dihitung"
      INSERT INTO records VALUES ('r1', 'cash', 10), ('r2', 'bank', 20), ('r3', 'side', 30), ('r4', 'cash', 40);
    ''');
    List<Object?> ids(String? account) => [
      for (final r in db.select(
        'SELECT r.id FROM records r JOIN accounts a ON a.id = r.account_id WHERE ${accountScope(1)} ORDER BY r.id',
        [account],
      ))
        r['id'],
    ];

    expect(ids(null), ['r1', 'r2', 'r4']); // as before: the excluded account stays out
    expect(ids('cash'), ['r1', 'r4']);
    expect(ids('side'), ['r3']); // picked on purpose, so its records show although it is not counted
  });
}
