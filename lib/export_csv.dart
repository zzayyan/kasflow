import 'package:intl/intl.dart';

// Pengaturan's "Ekspor transaksi": every confirmed record as one CSV, for a spreadsheet or a backup.

/// The columns, in order; [recordsCsv] fills them from the query in settings_page.dart.
const csvHeader = ['Tanggal', 'Jenis', 'Nominal', 'Mata uang', 'Akun', 'Ke akun', 'Kategori', 'Catatan', 'Label'];

const _typeNames = {'expense': 'Keluar', 'income': 'Masuk', 'transfer': 'Transfer'};

/// [rows] hold a record's `occurred_at` (UTC ISO 8601), `type`, `amount` (cents), `currency`,
/// `account`, `target`, `category`, `note` and `labels`. Times are local; amounts are whole units
/// with a "." before any cents, so a spreadsheet reads them as numbers. Starts with a UTF-8 byte
/// order mark so Excel shows "é" and the like correctly.
String recordsCsv(List<Map<String, dynamic>> rows) {
  final time = DateFormat('yyyy-MM-dd HH:mm');
  final lines = [
    csvHeader.map(_field).join(','),
    for (final r in rows)
      [
        time.format(DateTime.parse(r['occurred_at'] as String).toLocal()),
        _typeNames[r['type']] ?? '${r['type']}',
        _amount(r['amount'] as int),
        r['currency'],
        r['account'],
        r['target'],
        r['category'],
        r['note'],
        r['labels'],
      ].map(_field).join(','),
  ];
  return '\uFEFF${lines.join('\r\n')}\r\n';
}

String _amount(int cents) {
  final sign = cents < 0 ? '-' : '', whole = cents.abs() ~/ 100, rest = cents.abs() % 100;
  return rest == 0 ? '$sign$whole' : '$sign$whole.${rest.toString().padLeft(2, '0')}';
}

/// A CSV field: quoted when it holds a comma, quote or line break, with quotes doubled.
String _field(Object? value) {
  final s = value?.toString() ?? '';
  return s.contains(RegExp('[",\r\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
}
