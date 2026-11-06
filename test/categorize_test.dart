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

  test('normalizeKeyword', () {
    expect(normalizeKeyword('  Tiktok   Shop '), 'tiktok shop');
    expect(normalizeKeyword('7-Eleven'), '7-eleven');
    expect(normalizeKeyword('123'), null);
    expect(normalizeKeyword(''), null);
    expect(normalizeKeyword('x' * 31), null);
  });

  test('reassignKeywords: one keyword, one category; only changed lists returned', () {
    final current = {
      'makan': ['bakso', 'seblak'],
      'pendidikan': ['buku'],
      'hiburan': ['game'],
    };
    expect(reassignKeywords(current, 'makan', ['bakso', 'buku']), {
      'makan': ['bakso', 'buku'],
      'pendidikan': <String>[],
    });
    expect(reassignKeywords(current, 'baru', ['game']), {
      'hiburan': <String>[],
      'baru': ['game'],
    });
    expect(reassignKeywords(current, 'hiburan', ['game']), isEmpty);
  });

  test('only categories of the record type are considered', () {
    expect(guessCategoryId('Bonus kopi gratis', 'expense', categories), 'makan');
    expect(guessCategoryId('Gaji bulan November masuk', 'income', categories), 'gaji');
    expect(guessCategoryId('Gaji bulan November masuk', 'expense', categories), null);
  });

  test('noteSuggestions puts notes that start with the text first, and skips an exact match', () {
    const notes = ['Nasi Ayam', 'Ayam Goreng', 'ayam', 'Bakso', 'Ayam Bakar', 'Biaya admin', 'Es Teh'];
    expect(noteSuggestions(notes, 'ayam'), ['Ayam Goreng', 'Ayam Bakar', 'Nasi Ayam']);
    expect(noteSuggestions(notes, 'ay'), ['Ayam Goreng', 'ayam', 'Ayam Bakar', 'Nasi Ayam']); // not "Biaya admin"
    expect(noteSuggestions(notes, '  AYAM g'), ['Ayam Goreng']);
    expect(noteSuggestions(notes, ''), isEmpty);
    expect(noteSuggestions(notes, 'a', limit: 2).length, 2);
  });
}
