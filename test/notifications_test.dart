import 'package:cashflow_app/notifications.dart';
import 'package:flutter_test/flutter_test.dart';

// A real BRImo email as Gmail's notification showed it (bigText, cut by Gmail), name and numbers changed.
const briQris = '''Pembelian QRIS Berhasil
Halo NAMA PENGGUNA,
Berikut detail transaksi kamu di BRImo:
Total Transaksi
23.000
Tujuan
Gultik Nih, ST BUDI
QRIS Bayar
9360000210000000000
Nomor Referensi
245800000000
Tanggal Transaksi
05 Nov 2026, 12:00:17 WIB
Rekening Sumber Dana
1234 **** **** 567
Nama Sumber Dana
NAMA PENGGUNA
Jenis Transaksi
QRIS Bayar
Nama Merchant
Gultik Nih, ST BUDI
Catatan
makan siang
Nominal
Rp23.000
Biaya Admin
Rp0
WhatsApp 0812-12-14017
Email callbri@bri.co.id''';

void main() {
  test('redact keeps amounts and the merchant, drops the name, numbers and emails', () {
    final sent = redact(briQris, ['Nama', 'Pengguna']);
    expect(sent, isNot(contains('PENGGUNA')));
    expect(sent, isNot(contains('245800000000')));
    expect(sent, isNot(contains('1234 **** **** 567')));
    expect(sent, isNot(contains('0812-12-14017')));
    expect(sent, isNot(contains('callbri@bri.co.id')));
    expect(sent, allOf(contains('Total Transaksi\n23.000'), contains('Rp23.000'), contains('Gultik Nih, ST BUDI')));
    expect(sent, contains('05 Nov 2026, 12:00:17 WIB'));
  });

  test('bankReference reads BRI reference numbers in each layout', () {
    expect(bankReference(briQris), '245800000000');
    expect(bankReference('| No. Ref | | 2434 2956 9720 |'), '243429569720');
    expect(bankReference('Kamu membayar Rp25.000 ke Warung Bakso'), null);
  });

  test('mentionsAmount lets transactions through and stops texts with no rupiah amount', () {
    for (final text in [
      briQris,
      'Pembayaran sebesar Rp16.050 berhasil',
      'Top up Rp 50000 berhasil',
      'Transfer IDR 25,000.00 received',
      'Kamu menerima 1.500.000 dari Budi',
    ]) {
      expect(mentionsAmount(text), isTrue, reason: text);
    }
    for (final text in [
      'Selamat menikmati!\nPastikan pesananmu sudah sesuai. Jika menemukan masalah beritahu kami secepatnya, ya 🧡',
      'Flash Sale jam 20:00! Diskon 50% semua produk',
      'Pesananmu sedang dikirim',
    ]) {
      expect(mentionsAmount(text), isFalse, reason: text);
    }
  });

  group('checkAnswer', () {
    const answer = {
      'is_transaction': true,
      'amount': 23000,
      'type': 'expense',
      'payee': 'Gultik Nih, ST BUDI',
      'note': 'makan siang',
      'summary': 'Pembelian QRIS',
    };

    test('a transaction whose amount is in the text', () {
      expect(checkAnswer(answer, briQris), (
        amount: 2300000,
        type: 'expense',
        title: 'Gultik Nih, ST BUDI · makan siang',
        text: 'Pembelian QRIS',
      ));
    });

    test('not a transaction', () {
      expect(checkAnswer({...answer, 'is_transaction': false}, briQris), null);
    });

    test('an amount missing from the text leaves the type empty, so the form opens', () {
      expect(checkAnswer({...answer, 'amount': 32000}, briQris)?.type, null);
      expect(checkAnswer({...answer, 'type': 'gift'}, briQris)?.type, null);
    });

    test('a malformed answer still becomes an item to fill in', () {
      expect(checkAnswer({'is_transaction': true}, briQris), (
        amount: 0,
        type: null,
        title: null,
        text: 'Pembelian QRIS Berhasil',
      ));
    });
  });
}
