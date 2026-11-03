import 'package:intl/intl.dart';

// Amounts are stored as integer "cents": value x 100, for every currency.
// ponytail: fixed x100 is wrong for display of zero-decimal currencies like JPY; use ISO 4217 exponents when multi-currency ships.

/// Parses Indonesian-style input into cents. Accepts "25000", "25.000", "25.000,50",
/// "25rb", "1,5jt", "Rp 25.000". Returns null for anything that is not a positive amount.
int? parseAmount(String input) {
  var s = input.toLowerCase().replaceAll(RegExp(r'rp|\s'), '');
  var multiplier = 1;
  final suffix = RegExp(r'(rb|ribu|k|jt|juta)$').firstMatch(s);
  if (suffix != null) {
    multiplier = const {'rb': 1000, 'ribu': 1000, 'k': 1000, 'jt': 1000000, 'juta': 1000000}[suffix[0]]!;
    s = s.substring(0, suffix.start);
  }
  // In id-ID "." groups thousands and "," marks decimals.
  if (!RegExp(r'^\d{1,3}(\.\d{3})*(,\d+)?$|^\d+(,\d+)?$').hasMatch(s)) return null;
  final value = double.parse(s.replaceAll('.', '').replaceAll(',', '.')) * multiplier;
  final cents = (value * 100).round();
  return cents > 0 ? cents : null;
}

final _idr = NumberFormat.currency(locale: 'id_ID', symbol: 'Rp ', decimalDigits: 0);

String formatAmount(int cents) => _idr.format(cents / 100);

final _idrCompact = NumberFormat.compactCurrency(locale: 'id_ID', symbol: 'Rp ', decimalDigits: null);

/// Short form for tight spaces such as stat tiles: "Rp 25 rb", "Rp 1,25 jt".
String formatCompact(int cents) => _idrCompact.format(cents / 100);
