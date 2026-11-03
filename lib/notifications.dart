import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'money.dart';

// B1: the Android TransactionNotificationListener writes finance-app notifications
// to a file; this file imports them into the local-only `inbox` table for review.

const _channel = MethodChannel('cashflow/notifications');

Future<bool> notificationAccessEnabled() async => await _channel.invokeMethod<bool>('isEnabled') ?? false;

Future<void> openNotificationAccessSettings() => _channel.invokeMethod('openSettings');

// Keep in sync with FINANCE_PACKAGES in TransactionNotificationListener.kt.
// Values match the provider keys of accountPresets in main.dart.
const providerByPackage = {
  'com.gojek.app': 'gopay',
  'com.gojek.gopay': 'gopay',
  'id.dana': 'dana',
  'ovo.id': 'ovo',
  'com.shopee.id': 'shopeepay',
  'com.shopeepay.id': 'shopeepay',
  'id.co.bri.brimo': 'bri',
  'id.bmri.livin': 'mandiri',
  'com.jago.digitalBanking': 'jago',
  'id.co.bankbkemobile.digitalbank': 'seabank',
};

typedef ParsedNotification = ({int amount, String? type});

// ponytail: keyword heuristics written before seeing real notifications from these apps.
// The first amount wins and ambiguous wording leaves the type for the user to pick.
// Tune both with real samples (test/notifications_test.dart).
final _amountPattern = RegExp(r'(?:rp|idr)\.?\s?(\d[\d.,]*\d|\d)', caseSensitive: false);
final _promoPattern = RegExp(r'promo|voucher|diskon|kupon|hingga|s\.d\.?|s/d', caseSensitive: false);
const _incomeWords = ['masuk', 'diterima', 'menerima', 'terima', 'kredit', 'cashback', 'refund', 'pengembalian'];
const _expenseWords = [
  'bayar', 'transfer ke', 'kirim', 'debit', 'pembelian', 'beli', 'tarik tunai', 'keluar', 'terpotong', 'dipotong',
];

/// Returns null for notifications that are not a transaction (no amount, or a promotion).
ParsedNotification? parseNotification(String title, String text) {
  final all = '$title\n$text';
  if (_promoPattern.hasMatch(all)) return null;
  final match = _amountPattern.firstMatch(all);
  if (match == null) return null;
  final amount = _parseNotificationAmount(match[1]!);
  if (amount == null) return null;
  final lower = all.toLowerCase();
  final income = _incomeWords.any(lower.contains);
  final expense = _expenseWords.any(lower.contains);
  return (amount: amount, type: income == expense ? null : (income ? 'income' : 'expense'));
}

int? _parseNotificationAmount(String raw) {
  // "25,000" / "25,000.00" (English grouping) shows up in some apps next to Indonesian "25.000,00".
  final english = RegExp(r'^\d{1,3}(,\d{3})+(\.\d{1,2})?$').hasMatch(raw);
  return parseAmount(english ? raw.replaceAll(',', '').replaceAll('.', ',') : raw);
}

/// Moves captured notifications from the listener's file into the inbox table.
/// Returns how many new items were added.
Future<int> importNotifications() async {
  final dir = await getApplicationSupportDirectory();
  final inbox = File(join(dir.path, 'notification_inbox.jsonl'));
  if (!await inbox.exists()) return 0;
  // Rename first: the listener keeps appending to a fresh file while we read this one.
  final batch = await inbox.rename(join(dir.path, 'notification_inbox.${DateTime.now().microsecondsSinceEpoch}.jsonl'));
  var added = 0;
  for (final line in await batch.readAsLines()) {
    if (line.trim().isEmpty) continue;
    final Map<String, dynamic> n;
    try {
      n = jsonDecode(line) as Map<String, dynamic>;
    } on FormatException {
      continue; // half-written line from a crash; nothing to recover
    }
    final parsed = parseNotification(n['title'] as String? ?? '', n['text'] as String);
    if (parsed == null) continue;
    final ref = n['ref'] as String;
    final seen = await db.getOptional(
      'SELECT 1 FROM inbox WHERE ref = ?1 UNION ALL SELECT 1 FROM records WHERE source_ref = ?1 LIMIT 1',
      [ref],
    );
    if (seen != null) continue;
    await db.execute('''
      INSERT INTO inbox (id, ref, package, provider, title, text, amount, type, posted_at)
      VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?)''', [
      ref,
      n['package'],
      providerByPackage[n['package']],
      n['title'],
      n['text'],
      parsed.amount,
      parsed.type,
      DateTime.fromMillisecondsSinceEpoch(n['posted_at'] as int).toUtc().toIso8601String(),
    ]);
    added++;
  }
  await batch.delete();
  return added;
}
