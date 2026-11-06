import 'package:cashflow_app/export_csv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recordsCsv: local time, whole-unit amounts, quoted fields, BOM first', () {
    final at = DateTime(2026, 11, 6, 9, 5).toUtc().toIso8601String();
    final csv = recordsCsv([
      {
        'occurred_at': at,
        'type': 'expense',
        'amount': 2500000, // Rp 25.000
        'currency': 'IDR',
        'account': 'BRI',
        'target': null,
        'category': 'Makan & Minum',
        'note': 'Ayam "geprek", pedas',
        'labels': '#kantor',
      },
      {
        'occurred_at': at,
        'type': 'transfer',
        'amount': 150,
        'currency': 'IDR',
        'account': 'BRI',
        'target': 'GoPay',
        'category': null,
        'note': null,
        'labels': null,
      },
    ]);
    expect(csv.startsWith('﻿'), isTrue);
    final lines = csv.substring(1).split('\r\n');
    expect(lines[0], csvHeader.join(','));
    expect(lines[1], '2026-11-06 09:05,Keluar,25000,IDR,BRI,,Makan & Minum,"Ayam ""geprek"", pedas",#kantor');
    expect(lines[2], '2026-11-06 09:05,Transfer,1.50,IDR,BRI,GoPay,,,');
    expect(lines[3], ''); // ends with a line break
  });
}
