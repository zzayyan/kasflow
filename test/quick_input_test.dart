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
  geminiTests();

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

  test('hashtags become labels and leave the note', () {
    final e = parse('nasi padang 35rb #Liburan #bali-2026 pakai dana')!;
    expect((e.amount, e.note, e.accountId), (3500000, 'nasi padang', 'dana'));
    expect(e.labels, ['liburan', 'bali-2026']); // lists compare by identity inside records, so check apart
    expect(parse('#25rb kopi 18rb')!.labels, ['25rb']); // a hashtag is never the amount
    expect(parse('kopi 18rb #')!.labels, isEmpty); // a lone "#" is just a word
  });

  test('unknown words leave the category empty for the user to pick', () {
    final e = parse('seblak 15rb')!;
    expect((e.categoryId, e.note), (null, 'seblak'));
  });
}

// Gemini's answers to "Catat cepat" (supabase/functions/parse-quick-input), checked against the line.
void geminiTests() {
  List<QuickEntry> read(String input, List<Map<String, dynamic>> transactions) =>
      entriesFromAnswer({'transactions': transactions}, input, accounts: accounts, categories: categories, now: now);

  Map<String, dynamic> tx({
    int amount = 25000,
    String type = 'expense',
    String note = 'bakso',
    String account = 'none',
    String to = 'none',
    String category = 'makan',
    int daysAgo = 0,
  }) => {
    'amount': amount,
    'type': type,
    'note': note,
    'account_id': account,
    'transfer_account_id': to,
    'category_id': category,
    'days_ago': daysAgo,
  };

  test('several transactions in one line, with labels and a past date', () {
    final e = read('makan 25rb, parkir 5 rb kemarin pakai dana #liburan', [
      tx(note: 'makan', account: 'dana', daysAgo: 1),
      tx(amount: 5000, note: 'parkir', account: 'dana', category: 'transport', daysAgo: 1),
    ]);
    expect(
      [for (final x in e) (x.amount, x.categoryId, x.accountId, x.note, x.sure)],
      [(2500000, 'makan', 'dana', 'makan', true), (500000, 'transport', 'dana', 'parkir', true)],
    );
    expect(e.first.date, DateTime(2026, 11, 2, 14, 30));
    expect(e.first.labels, ['liburan']);
  });

  test('an amount that is not in the line is unsure, so the form opens', () {
    expect(read('bakso 25rb', [tx(amount: 52000)]).single.sure, false);
    expect(read('bakso 25rb', [tx(daysAgo: -3)]).single.sure, false);
  });

  test('unknown ids are dropped; a missing category falls back to keywords', () {
    final e = read('bakso 25rb', [tx(account: 'bri', category: 'none')]).single;
    expect((e.accountId, e.categoryId), (null, 'makan'));
    expect(read('gaji 5jt', [tx(amount: 5000000, type: 'income', category: 'makan')]).single.categoryId, null);
  });

  test('a transfer keeps its destination and no category', () {
    final e = read('top up dana 100rb dari bca', [
      tx(amount: 100000, type: 'transfer', note: 'top up', account: 'bca', to: 'dana'),
    ]).single;
    expect((e.type, e.accountId, e.transferAccountId, e.categoryId), ('transfer', 'bca', 'dana', null));
  });

  test('no transactions, or a malformed answer', () {
    expect(read('bakso enak', []), isEmpty);
    expect(entriesFromAnswer({}, 'x', accounts: accounts, categories: categories), isEmpty);
    expect(
      read('bakso 25rb', [
        {'amount': '25000'},
      ]),
      isEmpty,
    );
  });
}
