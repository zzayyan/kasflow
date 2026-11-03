import 'package:cashflow_app/money.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseAmount reads Indonesian amounts into cents', () {
    expect(parseAmount('25000'), 2500000);
    expect(parseAmount('25.000'), 2500000);
    expect(parseAmount('Rp 25.000'), 2500000);
    expect(parseAmount('25.000,50'), 2500050);
    expect(parseAmount('25rb'), 2500000);
    expect(parseAmount('1,5jt'), 150000000);
    expect(parseAmount('2 juta'), 200000000);
    expect(parseAmount('0'), null);
    expect(parseAmount('abc'), null);
    expect(parseAmount('25.00'), null); // ambiguous grouping is rejected, not guessed
  });

  test('formatAmount shows Rupiah without decimals', () {
    expect(formatAmount(2500000).replaceAll(' ', ' '), 'Rp 25.000');
  });
}
