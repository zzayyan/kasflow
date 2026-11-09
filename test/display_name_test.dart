import 'package:cashflow_app/db.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a nickname wins over the Google full name', () {
    final meta = {'nickname': 'zayyan', 'name': 'Brillianta Zayyan Muhammad', 'full_name': 'Brillianta Zayyan Muhammad'};
    expect(displayNameFrom(meta, 'a@gmail.com'), 'Zayyan');
  });

  test('without a nickname the Google full name is cut to its first word', () {
    expect(displayNameFrom({'name': 'Brillianta Zayyan Muhammad'}, 'a@gmail.com'), 'Brillianta');
    expect(displayNameFrom({'full_name': 'Brillianta Zayyan Muhammad'}, null), 'Brillianta');
  });

  test('falls back to the email prefix, then to Kamu', () {
    expect(displayNameFrom(null, 'budi@gmail.com'), 'Budi');
    expect(displayNameFrom({'name': '  '}, 'budi@gmail.com'), 'Budi');
    expect(displayNameFrom(null, null), 'Kamu');
  });
}
