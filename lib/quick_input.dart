import 'categorize.dart';
import 'money.dart';

// B2: one line of free text -> transactions. "Catat cepat" asks Gemini first
// (supabase/functions/parse-quick-input, read back by entriesFromAnswer); the plain rules in
// parseQuickInput fill the record form as the user types and stand in when Gemini is unreachable.
// "bakso 25rb pakai dana", "gaji masuk bca 5jt", "bensin 30rb kemarin".

class QuickEntry {
  const QuickEntry({
    required this.amount,
    required this.type,
    required this.note,
    required this.date,
    this.accountId,
    this.transferAccountId,
    this.categoryId,
    this.labels = const [],
    this.sure = true,
  });

  final int amount;
  final String type; // 'expense', 'income', or 'transfer' (Gemini only)
  final String note; // the words left after removing amount, account and date words
  final DateTime date;
  final String? accountId; // null: the caller picks a default
  final String? transferAccountId; // a transfer's destination
  final String? categoryId; // null: no keyword matched, ask the user
  final List<String> labels; // label names from hashtags, "#liburan" -> "liburan"
  final bool sure; // false: the form opens for the user to check (Gemini's amount is not in the line)
}

/// The transactions in Gemini's [answer] for the line [input]. Only ids found in [accounts] and
/// [categories] are kept. An amount that does not appear in the line, or an odd date, marks the
/// entry unsure, so the form opens to check it instead of saving a made-up number.
List<QuickEntry> entriesFromAnswer(
  Map<String, dynamic> answer,
  String input, {
  required List<Map<String, dynamic>> accounts,
  required List<Map<String, dynamic>> categories,
  DateTime? now,
}) {
  now ??= DateTime.now();
  final amounts = {
    for (final t in _joinSuffixes(input).split(RegExp(r'\s+'))) ?parseAmount(t.replaceFirst(RegExp(r'[,;.]$'), '')),
  };
  final labels = [for (final m in RegExp(r'#(\S+)').allMatches(input)) m[1]!.toLowerCase()];
  String? account(Object? id) => accounts.any((a) => a['id'] == id) ? id as String : null;
  final transactions = answer['transactions'];
  final entries = <QuickEntry>[];
  for (final t in transactions is List ? transactions.whereType<Map<String, dynamic>>() : <Map<String, dynamic>>[]) {
    final rupiah = t['amount'];
    if (rupiah is! int || rupiah <= 0) continue;
    final type = const {'expense', 'income', 'transfer'}.contains(t['type']) ? t['type'] as String : 'expense';
    final note = t['note'] is String ? (t['note'] as String).trim() : '';
    final daysAgo = t['days_ago'] is int ? t['days_ago'] as int : -1;
    final dated = daysAgo >= 0 && daysAgo <= 366;
    final categoryId = categories.any((c) => c['id'] == t['category_id'] && c['type'] == type)
        ? t['category_id'] as String
        : guessCategoryId(note, type, categories);
    entries.add(
      QuickEntry(
        amount: rupiah * 100,
        type: type,
        note: note,
        date: DateTime(now.year, now.month, now.day - (dated ? daysAgo : 0), now.hour, now.minute),
        accountId: account(t['account_id']),
        transferAccountId: type == 'transfer' ? account(t['transfer_account_id']) : null,
        categoryId: type == 'transfer' ? null : categoryId,
        labels: labels,
        sure: amounts.contains(rupiah * 100) && dated,
      ),
    );
  }
  return entries;
}

/// "25 rb" -> "25rb", so an amount is a single token.
String _joinSuffixes(String input) => input.trim().replaceAllMapped(
  RegExp(r'(\d)\s+(rb|ribu|k|jt|juta)\b', caseSensitive: false),
  (m) => '${m[1]}${m[2]}',
);

const _incomeWords = {
  'gaji',
  'terima',
  'diterima',
  'dapat',
  'dapet',
  'masuk',
  'bonus',
  'thr',
  'cashback',
  'refund',
  'jual',
  'untung',
};
const _accountConnectors = {'pakai', 'pake', 'pakek', 'via', 'dari', 'lewat', 'ke'};
const _accountAliases = {
  'cash': {'cash', 'tunai', 'cas', 'dompet'},
};
final _suffixOrGrouping = RegExp(r'(rb|ribu|k|jt|juta)$|\d[.,]\d', caseSensitive: false);

/// Why the plain rules may have misread [input], worded as a nudge to ask AI. Null when [entry] is
/// missing (no amount yet) or the reading looks right. Never calls Gemini: the user decides that.
String? quickInputHint(String input, QuickEntry? entry) {
  if (entry == null) return null;
  if (RegExp(r'\b(transfer|trf|tf|kirim|pindah)\b', caseSensitive: false).hasMatch(input)) {
    return 'Sepertinya transfer. Tekan AI untuk mengisi akunnya.';
  }
  final amounts = _joinSuffixes(input).split(RegExp(r'\s+')).where((t) {
    final word = t.replaceFirst(RegExp(r'[,;.]$'), '');
    return parseAmount(word) != null && (_suffixOrGrouping.hasMatch(word) || RegExp(r'^\d{4,}$').hasMatch(word));
  }).length;
  if (amounts > 1) return 'Ada $amounts nominal. Tekan AI untuk membaca semuanya.';
  if (entry.categoryId == null) return 'Kategori belum dikenali. Tekan AI untuk menebaknya.';
  return null;
}

/// Returns null when the text has no amount.
/// [accounts] rows need `id`, `name`, `provider`; [categories] rows need `id`, `type`, `keywords`.
QuickEntry? parseQuickInput(
  String input, {
  required List<Map<String, dynamic>> accounts,
  required List<Map<String, dynamic>> categories,
  DateTime? now,
}) {
  now ??= DateTime.now();
  final joined = _joinSuffixes(input);
  final tokens = joined.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  final lower = [for (final t in tokens) t.toLowerCase()];
  final used = <int>{};

  // Labels: "#liburan" tokens. Taken out first so "#25rb" stays a label, not an amount.
  final labels = <String>[];
  for (var i = 0; i < tokens.length; i++) {
    if (tokens[i].length > 1 && tokens[i].startsWith('#')) {
      labels.add(tokens[i].substring(1).toLowerCase());
      used.add(i);
    }
  }

  // Amount: prefer tokens that look like money ("25rb", "25.000") over bare numbers, then the larger one,
  // so "beli 2 kopi 30rb" reads 30rb, not 2.
  int? amount;
  var amountIndex = -1;
  var amountRank = -1;
  for (var i = 0; i < tokens.length; i++) {
    if (used.contains(i)) continue;
    final value = parseAmount(tokens[i]);
    if (value == null) continue;
    final rank = _suffixOrGrouping.hasMatch(tokens[i]) ? 1 : 0;
    if (rank > amountRank || (rank == amountRank && value > amount!)) {
      amount = value;
      amountIndex = i;
      amountRank = rank;
    }
  }
  if (amount == null) return null;
  used.add(amountIndex);
  if (amountIndex > 0 && lower[amountIndex - 1] == 'rp') used.add(amountIndex - 1);

  // Account: a word equal to an account name or preset ("dana", "gopay", "tunai").
  String? accountId;
  for (final a in accounts) {
    final provider = (a['provider'] as String?)?.toLowerCase();
    final names = {(a['name'] as String).toLowerCase(), ?provider, ...?_accountAliases[provider]};
    final i = Iterable<int>.generate(tokens.length)
        .where((i) => !used.contains(i))
        .where((i) => names.contains(lower[i]))
        .firstOrNull;
    if (i == null) continue;
    accountId = a['id'] as String;
    used.add(i);
    if (i > 0 && _accountConnectors.contains(lower[i - 1])) used.add(i - 1);
    break;
  }

  // Date: "kemarin", "kemarin lusa", "3 hari lalu". Everything else is today.
  var daysAgo = 0;
  for (var i = 0; i < tokens.length; i++) {
    if (used.contains(i)) continue;
    if (lower[i] == 'kemarin') {
      final lusa = i + 1 < tokens.length && lower[i + 1] == 'lusa';
      daysAgo = lusa ? 2 : 1;
      used.addAll([i, if (lusa) i + 1]);
    } else if (i + 2 < tokens.length && lower[i + 1] == 'hari' && lower[i + 2] == 'lalu') {
      final n = int.tryParse(lower[i]);
      if (n == null) continue;
      daysAgo = n;
      used.addAll([i, i + 1, i + 2]);
    }
  }
  final date = DateTime(now.year, now.month, now.day - daysAgo, now.hour, now.minute);

  final note = [
    for (var i = 0; i < tokens.length; i++)
      if (!used.contains(i)) tokens[i],
  ].join(' ');
  final incomeCategory = guessCategoryId(note, 'income', categories);
  final expenseCategory = guessCategoryId(note, 'expense', categories);
  final income = lower.any(_incomeWords.contains) || (incomeCategory != null && expenseCategory == null);

  return QuickEntry(
    amount: amount,
    type: income ? 'income' : 'expense',
    note: note,
    date: date,
    accountId: accountId,
    categoryId: income ? incomeCategory : expenseCategory,
    labels: labels,
  );
}
