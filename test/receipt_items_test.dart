import 'package:cashflow_app/receipt_items.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Gemini lines become cents, and broken lines are dropped', () {
    final items = itemsFromReceipt([
      {'name': ' Teh Tarik Dingin ', 'qty': 1, 'amount': 33000},
      {'name': 'Nasi Putih', 'qty': 2, 'amount': 13200},
      {'name': '', 'qty': 1, 'amount': 5000}, // no name
      {'name': 'Diskon', 'qty': 1, 'amount': -5000}, // not a bought line
      {'name': 'Kerupuk', 'qty': 0, 'amount': 2000}, // qty missing: 1
      'garbage',
    ]);
    expect(items, const [
      ReceiptItem(name: 'Teh Tarik Dingin', qty: 1, amount: 3300000),
      ReceiptItem(name: 'Nasi Putih', qty: 2, amount: 1320000),
      ReceiptItem(name: 'Kerupuk', qty: 1, amount: 200000),
    ]);
    expect(itemsFromReceipt(null), isEmpty);
    expect(itemsFromReceipt(List.filled(150, {'name': 'x', 'qty': 1, 'amount': 1})).length, maxReceiptItems);
  });

  test('the stored column round-trips, and no items stores null', () {
    const items = [ReceiptItem(name: 'Ayam "Rempah"', qty: 1, amount: 2530000)];
    expect(itemsOf(encodeItems(items)), items);
    expect(encodeItems(const []), isNull);
    expect(itemsOf(null), isEmpty);
    expect(itemsOf('not json'), isEmpty);
    expect(itemsOf([
      {'name': 'Tempe', 'qty': 1, 'amount': 660000},
    ]), const [ReceiptItem(name: 'Tempe', qty: 1, amount: 660000)]);
  });

  test('the gap is what the lines leave out of the total', () {
    const items = [
      ReceiptItem(name: 'Kopi', qty: 1, amount: 3000000),
      ReceiptItem(name: 'Roti', qty: 1, amount: 2000000),
    ];
    expect(itemsGap(items, 5500000), 500000); // tax
    expect(itemsGap(items, 4500000), -500000); // a bill discount
    expect(itemsGap(items, 5000000), 0);
  });
}
