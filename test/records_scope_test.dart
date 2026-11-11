import 'package:cashflow_app/screens/records_tab.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('ofAccount: a transfer shows under both of its accounts', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute('''
      CREATE TABLE records (id TEXT, account_id TEXT, transfer_account_id TEXT);
      INSERT INTO records VALUES ('r1', 'cash', NULL), ('r2', 'cash', 'bank'), ('r3', 'bank', NULL);
    ''');
    List<Object?> ids(String? account) => [
      for (final r in db.select('SELECT r.id FROM records r WHERE ${ofAccount(1)} ORDER BY r.id', [account])) r['id'],
    ];

    expect(ids(null), ['r1', 'r2', 'r3']);
    expect(ids('cash'), ['r1', 'r2']);
    expect(ids('bank'), ['r2', 'r3']); // the transfer lands here too
  });
}
