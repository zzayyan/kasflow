import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'money.dart';

// B1: the Android TransactionNotificationListener writes finance-app notifications to a file.
// importNotifications() queues them in the local-only `inbox` table (amount NULL: not read yet),
// then Gemini reads each one through the parse-transaction Edge Function
// (supabase/functions/parse-transaction). Offline or over quota, they wait for the next try.

final _log = Logger('notifications');

const _channel = MethodChannel('cashflow/notifications');

Future<bool> notificationAccessEnabled() async => await _channel.invokeMethod<bool>('isEnabled') ?? false;

Future<void> openNotificationAccessSettings() => _channel.invokeMethod('openSettings');

// Keep in sync with FINANCE_PACKAGES and GMAIL in TransactionNotificationListener.kt.
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
  'com.google.android.gm': 'bri', // only BRI emails get past the listener's sender check
};

// The bank's own transaction number keeps one transaction one inbox item, even when an app
// re-posts its notification or the same transfer arrives by email and by push. Read here on the
// phone, because redact() removes it before Gemini sees the text.
final _referencePattern = RegExp(r'(?:Nomor Referensi|No\. ?Ref)\W*(\d[\d ]{4,}\d)', caseSensitive: false);

String? bankReference(String text) => _referencePattern.firstMatch(text)?[1]!.replaceAll(' ', '');

/// The copy of a notification that leaves the phone: [text] without the user's [names],
/// email addresses or long numbers (accounts, cards, phones, references). Amounts stay,
/// being short or written with separators ("23.000", "Rp1.500.000").
String redact(String text, Iterable<String> names) {
  var out = text.replaceAll(RegExp(r'\S+@\S+\.\S+'), '[email]').replaceAll(RegExp(r'\d[\d *-]{6,}\d'), '[nomor]');
  for (final name in names) {
    out = out.replaceAll(RegExp('\\b${RegExp.escape(name)}\\b', caseSensitive: false), '[nama]');
  }
  return out;
}

// "Rp16.050", "Rp 50000", "IDR 25,000", or a grouped number like "1.500.000".
final _amountPattern = RegExp(r'(?:\bRp|\bIDR)\.?\s?\d|\d[.,]\d{3}\b', caseSensitive: false);

/// Whether [text] names a rupiah amount. Every transaction does, so texts without one (order
/// updates, chats, "Diskon 50%" promos) are dropped on the phone and never use the Gemini quota.
bool mentionsAmount(String text) => _amountPattern.hasMatch(text);

typedef ReadNotification =({int amount, String? type, String? title, String text});

/// Checks Gemini's [answer] against the [original] notification. Null when it is not a transaction.
/// When the amount cannot be found in the original, the type stays empty, so saving the item
/// opens the form for the user to check instead of saving a made-up number.
ReadNotification? checkAnswer(Map<String, dynamic> answer, String original) {
  if (answer['is_transaction'] != true) return null;
  final rupiah = answer['amount'];
  final amount = rupiah is int && rupiah > 0 ? rupiah * 100 : 0;
  final found = _amountsIn(original).contains(amount);
  final type = answer['type'];
  String? clean(Object? s) => s is String && s.trim().isNotEmpty && s.trim() != '-' ? s.trim() : null;
  final title = [?clean(answer['payee']), ?clean(answer['note'])].join(' · ');
  return (
    amount: amount,
    type: found && const {'expense', 'income', 'transfer'}.contains(type) ? type as String : null,
    title: title.isEmpty ? null : title,
    text: clean(answer['summary']) ?? original.trim().split('\n').first,
  );
}

Set<int> _amountsIn(String text) => {
  for (final m in RegExp(r'\d[\d.,]*\d|\d').allMatches(text)) ?_parseNotificationAmount(m[0]!),
};

int? _parseNotificationAmount(String raw) {
  // "25,000" / "25,000.00" (English grouping) shows up in some apps next to Indonesian "25.000,00".
  final english = RegExp(r'^\d{1,3}(,\d{3})+(\.\d{1,2})?$').hasMatch(raw);
  return parseAmount(english ? raw.replaceAll(',', '').replaceAll('.', ',') : raw);
}

Future<File> _inboxFile() async =>
    File(join((await getApplicationSupportDirectory()).path, 'notification_inbox.jsonl'));

/// Whether the listener has written notifications that are not imported yet. Cheap enough to poll.
Future<bool> notificationsWaiting() async => (await _inboxFile()).exists();

/// Moves captured notifications from the listener's file into the inbox queue, then has
/// Gemini read the queue. Returns how many items became ready for review.
// One import at a time: a resume and the poll landing together must not both rename the file.
Future<int> importNotifications() => _importing ??= _import().whenComplete(() => _importing = null);

Future<int>? _importing;

Future<int> _import() async {
  final inbox = await _inboxFile();
  if (await inbox.exists()) {
    final dir = inbox.parent;
    // Rename first: the listener keeps appending to a fresh file while we read this one.
    final batch = await inbox.rename(
      join(dir.path, 'notification_inbox.${DateTime.now().microsecondsSinceEpoch}.jsonl'),
    );
    for (final line in await batch.readAsLines()) {
      if (line.trim().isEmpty) continue;
      final Map<String, dynamic> n;
      try {
        n = jsonDecode(line) as Map<String, dynamic>;
      } on FormatException {
        continue; // half-written line from a crash; nothing to recover
      }
      final text = n['text'] as String;
      if (!mentionsAmount('${n['title']}\n$text')) continue;
      final number = bankReference(text);
      final ref = number == null ? n['ref'] as String : 'ref|$number';
      final seen = await db.getOptional(
        'SELECT 1 FROM inbox WHERE ref = ?1 UNION ALL SELECT 1 FROM records WHERE source_ref = ?1 LIMIT 1',
        [ref],
      );
      if (seen != null) continue;
      await db.execute(
        'INSERT INTO inbox (id, ref, package, provider, title, text, posted_at) VALUES (uuid(), ?, ?, ?, ?, ?, ?)',
        [
          ref,
          n['package'],
          providerByPackage[n['package']],
          n['title'],
          text,
          DateTime.fromMillisecondsSinceEpoch(n['posted_at'] as int).toUtc().toIso8601String(),
        ],
      );
    }
    await batch.delete();
  }
  return _readQueue();
}

// ponytail: 10 a run stays under the free tier's 15 requests a minute; the rest wait for the
// next app open. Batch several notifications per request if queues grow past that.
// Newest first: the payment just made shows up at once instead of waiting behind older items.
Future<int> _readQueue() async {
  final queued = await db.getAll(
    'SELECT id, title, text FROM inbox WHERE amount IS NULL ORDER BY posted_at DESC LIMIT 10',
  );
  if (queued.isEmpty) return 0;
  final meta = supabase.auth.currentUser?.userMetadata;
  final names = '${meta?['name'] ?? meta?['full_name'] ?? ''}'.split(RegExp(r'\s+')).where((w) => w.length >= 3);
  var ready = 0;
  for (final n in queued) {
    final original = [n['title'], n['text']].whereType<String>().join('\n');
    final Map<String, dynamic> answer;
    try {
      final response = await supabase.functions
          .invoke('parse-transaction', body: {'text': redact(original, names)})
          .timeout(const Duration(seconds: 20)); // a hung request would block the queue until restart
      // A malformed answer still becomes an item (amount 0) for the user to fill, never a stuck queue.
      final data = response.data;
      answer = data is Map<String, dynamic> ? data : const {'is_transaction': true};
    } on Exception catch (e) {
      _log.warning('Notification left queued for the next try', e); // offline, quota, or Gemini down
      break;
    }
    final read = checkAnswer(answer, original);
    if (read == null) {
      await db.execute('DELETE FROM inbox WHERE id = ?', [n['id']]);
      continue;
    }
    await db.execute('UPDATE inbox SET title = ?, text = ?, amount = ?, type = ? WHERE id = ?', [
      read.title,
      read.text,
      read.amount,
      read.type,
      n['id'],
    ]);
    ready++;
  }
  return ready;
}
