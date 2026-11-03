import 'package:cashflow_app/quick_input.dart';
import 'package:flutter_test/flutter_test.dart';

final accounts = [
  {'id': 'dana', 'name': 'DANA', 'provider': 'dana'},
  {'id': 'bca', 'name': 'BCA', 'provider': 'bca'},
  {'id': 'dompet', 'name': 'Dompet', 'provider': 'cash'},
];
final categories = [
  {'id': 'makan', 'type': 'expense', 'keywords': '["makan","bakso","kopi","mixue"]'},
  {'id': 'transport', 'type': 'expense', 'keywords': '["bensin","parkir","grab"]'},
  {'id': 'gaji', 'type': 'income', 'keywords': '["gaji","bonus"]'},
];
final now = DateTime(2026, 11, 3, 14, 30);

QuickEntry? parse(String s) => parseQuickInput(s, accounts: accounts, categories: categories, now: now);

void main() {
  test('amount, category and account from one line', () {
    final e = parse('bakso 25rb pakai dana')!;
    expect((e.amount, e.type, e.categoryId, e.accountId, e.note), (2500000, 'expense', 'makan', 'dana', 'bakso'));
  });

  test('amount formats', () {
    expect(parse('kopi 25.000')!.amount, 2500000);
    expect(parse('kopi Rp 18.500')!.amount, 1850000);
    expect(parse('kopi 25 rb')!.amount, 2500000);
    expect(parse('servis motor 1,5jt')!.amount, 150000000);
    expect(parse('beli 2 kopi 30rb')!.amount, 3000000); // money-looking token beats the bare "2"
    expect(parse('parkir 5000')!.amount, 500000);
    expect(parse('bakso enak'), null);
  });

  test('income from words or income-only categories', () {
    final e = parse('gaji masuk bca 5jt')!;
    expect((e.type, e.categoryId, e.accountId, e.note), ('income', 'gaji', 'bca', 'gaji masuk'));
    expect(parse('dapat transferan 100rb')!.type, 'income');
    expect(parse('bonus 1jt')!.type, 'income');
  });

  test('cash aliases and no account', () {
    expect(parse('bensin 30rb tunai')!.accountId, 'dompet');
    expect(parse('bensin 30rb')!.accountId, null);
  });

  test('dates', () {
    expect(parse('bensin 30rb kemarin')!.date, DateTime(2026, 11, 2, 14, 30));
    expect(parse('kemarin lusa makan 20rb')!.date, DateTime(2026, 11, 1, 14, 30));
    expect(parse('makan 20rb 3 hari lalu')!.date, DateTime(2026, 10, 31, 14, 30));
    expect(parse('makan 20rb')!.date, now);
    expect(parse('bensin 30rb kemarin')!.note, 'bensin');
  });

  test('unknown words leave the category empty for the user to pick', () {
    final e = parse('seblak 15rb')!;
    expect((e.categoryId, e.note), (null, 'seblak'));
  });
}
