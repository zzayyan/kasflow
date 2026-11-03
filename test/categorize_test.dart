import 'package:cashflow_app/categorize.dart';
import 'package:flutter_test/flutter_test.dart';

// Keywords copied from the signup seed in supabase/migrations/0001_init.sql.
final categories = [
  {'id': 'makan', 'type': 'expense', 'keywords': '["makan","minum","bakso","kopi","nasi","jajan","gofood","grabfood"]'},
  {'id': 'transport', 'type': 'expense', 'keywords': '["bensin","parkir","tol","gojek","grab","ojek","krl","mrt"]'},
  {'id': 'tagihan', 'type': 'expense', 'keywords': '["listrik","pln","air","pdam","internet","wifi","pulsa","token"]'},
  {'id': 'lainnya', 'type': 'expense', 'keywords': '[]'},
  {'id': 'gaji', 'type': 'income', 'keywords': '["gaji","salary","thr","bonus"]'},
];

void main() {
  test('matches keywords as whole words, case-insensitive', () {
    expect(guessCategoryId('Kamu membayar Rp25.000 ke Warung BAKSO', 'expense', categories), 'makan');
    expect(guessCategoryId('Token listrik PLN 100rb', 'expense', categories), 'tagihan');
    expect(guessCategoryId('Perjalanan ke Kairo', 'expense', categories), null); // "air" inside a word
  });

  test('longest keyword wins', () {
    expect(guessCategoryId('Pembayaran GrabFood berhasil', 'expense', categories), 'makan');
    expect(guessCategoryId('Pembayaran Grab berhasil', 'expense', categories), 'transport');
  });

  test('keywordFromNote keeps short typed phrases only', () {
    expect(keywordFromNote('Mixue'), 'mixue');
    expect(keywordFromNote('  es teh  manis '), 'es teh manis');
    expect(keywordFromNote('seblak 15rb'), 'seblak');
    expect(keywordFromNote('25rb'), null);
    expect(keywordFromNote('makan siang bareng tim kantor'), null);
  });

  test('only categories of the record type are considered', () {
    expect(guessCategoryId('Bonus kopi gratis', 'expense', categories), 'makan');
    expect(guessCategoryId('Gaji bulan November masuk', 'income', categories), 'gaji');
    expect(guessCategoryId('Gaji bulan November masuk', 'expense', categories), null);
  });
}
