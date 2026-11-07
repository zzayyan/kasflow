import 'dart:convert';

// The lines of a scanned receipt, kept on its record (records.items, a JSON array). Pure logic, no
// Flutter or database, so it is unit-tested.

/// One printed line: [amount] is the line total in cents, like records.amount.
class ReceiptItem {
  const ReceiptItem({required this.name, required this.qty, required this.amount});

  final String name;
  final int qty;
  final int amount;

  ReceiptItem copyWith({String? name, int? amount}) =>
      ReceiptItem(name: name ?? this.name, qty: qty, amount: amount ?? this.amount);

  Map<String, Object> toJson() => {'name': name, 'qty': qty, 'amount': amount};

  @override
  bool operator ==(Object other) =>
      other is ReceiptItem && other.name == name && other.qty == qty && other.amount == amount;

  @override
  int get hashCode => Object.hash(name, qty, amount);

  @override
  String toString() => 'ReceiptItem($name, $qty, $amount)';
}

/// The most lines a receipt keeps; anything past it is dropped.
const maxReceiptItems = 100;

/// Gemini's `items` (amounts in whole rupiah) as receipt lines. Lines with no name or no positive
/// amount are dropped, so a bad answer leaves fewer lines, never a broken record.
List<ReceiptItem> itemsFromReceipt(Object? raw) =>
    raw is List ? raw.take(maxReceiptItems).map((e) => _line(e, rupiah: true)).nonNulls.toList() : [];

/// The items column as stored: a JSON array (text in SQLite), or null for a record without a receipt.
List<ReceiptItem> itemsOf(Object? column) {
  final raw = column is String ? _decode(column) : column;
  return raw is List ? raw.map((e) => _line(e, rupiah: false)).nonNulls.toList() : [];
}

/// The items column to write: a JSON array, or null when there are none.
String? encodeItems(List<ReceiptItem> items) =>
    items.isEmpty ? null : jsonEncode([for (final i in items) i.toJson()]);

/// What the lines leave out of the [total] (tax, service, rounding, a bill discount): positive when
/// the total is more than the lines add up to.
int itemsGap(List<ReceiptItem> items, int total) => total - items.fold(0, (sum, i) => sum + i.amount);

ReceiptItem? _line(Object? e, {required bool rupiah}) {
  if (e is! Map) return null;
  final (name, qty, amount) = (e['name'], e['qty'], e['amount']);
  final n = name is String ? name.trim() : '';
  final a = amount is num ? (rupiah ? amount * 100 : amount).round() : 0;
  if (n.isEmpty || a <= 0) return null;
  return ReceiptItem(name: n, qty: qty is num && qty >= 1 ? qty.toInt() : 1, amount: a);
}

Object? _decode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}
