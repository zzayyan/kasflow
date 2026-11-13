import 'package:cashflow_app/db.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a nickname wins over the Google full name', () {
    final meta = {'nickname': 'rara', 'name': 'Siti Rahma Lestari', 'full_name': 'Siti Rahma Lestari'};
    expect(displayNameFrom(meta, 'a@gmail.com'), 'Rara');
  });

  test('without a nickname the Google full name is cut to its first word', () {
    expect(displayNameFrom({'name': 'Siti Rahma Lestari'}, 'a@gmail.com'), 'Siti');
    expect(displayNameFrom({'full_name': 'Siti Rahma Lestari'}, null), 'Siti');
  });

  test('falls back to the email prefix, then to Kamu', () {
    expect(displayNameFrom(null, 'budi@gmail.com'), 'Budi');
    expect(displayNameFrom({'name': '  '}, 'budi@gmail.com'), 'Budi');
    expect(displayNameFrom(null, null), 'Kamu');
  });
}
