import 'package:cashflow_app/notifications.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic texts written before real samples were collected. Replace or extend them with
// real (anonymised) notifications from each app when tuning the heuristics.
void main() {
  test('expense notifications', () {
    expect(parseNotification('Pembayaran berhasil', 'Kamu membayar Rp25.000 ke Warung Bakso'),
        (amount: 2500000, type: 'expense'));
    expect(parseNotification('Transfer', 'Transfer ke BUDI sebesar Rp 1.500.000 berhasil'),
        (amount: 150000000, type: 'expense'));
  });

  test('income notifications', () {
    expect(parseNotification('Dana masuk', 'Kamu menerima Rp100.000 dari SITI'),
        (amount: 10000000, type: 'income'));
    expect(parseNotification('Transaksi', 'Uang masuk IDR 250,000.00'), (amount: 25000000, type: 'income'));
  });

  test('ambiguous wording leaves the type to the user', () {
    expect(parseNotification('Info', 'Transaksi Rp50.000'), (amount: 5000000, type: null));
  });

  test('promotions and texts without an amount are not transactions', () {
    expect(parseNotification('Promo!', 'Diskon hingga Rp50.000 khusus hari ini'), null);
    expect(parseNotification('GoPay', 'Login baru terdeteksi di perangkat lain'), null);
  });
}
