import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';

import '../categorize.dart';
import '../db.dart';
import '../home_widget.dart';
import '../money.dart';
import '../notifications.dart';
import '../quick_input.dart';
import '../reports.dart';
import '../theme.dart';
import '../ui.dart';
import 'accounts_tab.dart';
import 'labels_page.dart';
import 'record_form.dart';

// A1 record list, B2 quick input and B1 notification inbox: the Transaksi tab, after the
// "E · Transaksi" and "Geser + snackbar" artboards of the Cashflow UI/UX canvas.

final _log = Logger('quick_input');

class RecordsTab extends StatefulWidget {
  const RecordsTab({super.key});

  @override
  State<RecordsTab> createState() => _RecordsTabState();
}

class _RecordsTabState extends State<RecordsTab> {
  static const _select = '''
    SELECT r.*, a.name AS account_name, t.name AS target_name, c.name AS category_name, c.icon AS category_icon,
      (SELECT group_concat('#' || l.name, ' ') FROM json_each(r.label_ids) j JOIN labels l ON l.id = j.value)
        AS label_names
    FROM records r
    LEFT JOIN accounts a ON a.id = r.account_id
    LEFT JOIN accounts t ON t.id = r.transfer_account_id
    LEFT JOIN categories c ON c.id = r.category_id''';

  // ponytail: newest 500 only; add paging when a user has more history than that.
  static Stream<List<Map<String, dynamic>>> _latest() =>
      db.watch('$_select ORDER BY julianday(r.occurred_at) DESC LIMIT 500');

  /// A record's date inside a month, taking the month's start and end as parameters [from] and [to].
  static String _within(int from, int to) =>
      'julianday(r.occurred_at) >= julianday(?$from) AND julianday(r.occurred_at) < julianday(?$to)';

  /// Every record of [month], however many.
  static Stream<List<Map<String, dynamic>>> _inMonth(DateTime month) {
    final (start, end) = periodRange('month', month);
    return db.watch(
      '$_select WHERE ${_within(1, 2)} ORDER BY julianday(r.occurred_at) DESC',
      parameters: [utcIso(start), utcIso(end)],
    );
  }

  /// Every record, however old (only those of [month] when given), whose note, category, account, label or
  /// amount holds [text].
  /// ponytail: % and _ typed in the search act as LIKE wildcards; escape them if that ever bites.
  static Stream<List<Map<String, dynamic>>> _matching(String text, DateTime? month) {
    final digits = text.replaceAll(RegExp(r'[^0-9]'), '');
    final range = month == null ? null : periodRange('month', month);
    return db.watch(
      '''
      $_select
      WHERE (lower(coalesce(r.note, '')) LIKE ?1 OR lower(coalesce(c.name, '')) LIKE ?1
        OR lower(coalesce(a.name, '')) LIKE ?1 OR lower(coalesce(t.name, '')) LIKE ?1
        OR EXISTS (SELECT 1 FROM json_each(r.label_ids) j JOIN labels l ON l.id = j.value
          WHERE lower('#' || l.name) LIKE ?1)
        OR (?2 != '' AND CAST(r.amount / 100 AS TEXT) LIKE '%' || ?2 || '%'))
        ${range == null ? '' : 'AND ${_within(3, 4)}'}
      ORDER BY julianday(r.occurred_at) DESC LIMIT $_searchLimit''',
      parameters: [
        '%${text.toLowerCase()}%',
        digits,
        if (range != null) ...[utcIso(range.$1), utcIso(range.$2)],
      ],
    );
  }

  /// The rows for a picked [month] (null: none picked) and a search [text] (empty: not searching).
  static Stream<List<Map<String, dynamic>>> _watch(DateTime? month, String text) => text.isNotEmpty
      ? _matching(text, month)
      : month == null
      ? _latest()
      : _inMonth(month);

  static const _searchLimit = 300;

  String? _type; // filter; null shows every type
  DateTime? _month; // filter: the first day of the picked month; null shows every month, newest first
  bool _searching = false;
  String _query = '';
  late Stream<List<Map<String, dynamic>>> _rows = _latest(); // a new watch per State: one listener each
  Timer? _debounce;
  final _search = TextEditingController();

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onQuery(String text) {
    _debounce?.cancel();
    // Wait for a pause in typing before querying again.
    _debounce = Timer(const Duration(milliseconds: 250), () {
      final q = text.trim();
      if (!mounted || q == _query) return;
      setState(() {
        _query = q;
        _rows = _watch(_month, q);
      });
    });
  }

  void _closeSearch() {
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _searching = false;
      _query = '';
      _rows = _watch(_month, '');
    });
  }

  void _setMonth(DateTime? month) => setState(() {
    _month = month;
    _rows = _watch(month, _query);
  });

  Future<void> _pickMonth() async {
    final picked = await pickMonth(context, _month);
    if (picked != null) _setMonth(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    const pill = OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(23)), borderSide: BorderSide.none);
    final month = _month;
    final inMonth = month == null ? '' : ' di ${DateFormat('MMMM yyyy', 'id_ID').format(month)}';
    return PopScope(
      // Back closes the search first, then leaves as usual.
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeSearch();
      },
      child: SafeArea(
        bottom: false,
        child: StreamBuilder(
          stream: _rows,
          builder: (context, snap) {
            final rows = snap.data?.where((r) => _type == null || r['type'] == _type).toList();
            return ListView(
              padding: const EdgeInsets.fromLTRB(AppSpace.page, 16, AppSpace.page, 24),
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 46),
                  child: _searching
                      ? TextField(
                          controller: _search,
                          autofocus: true,
                          onChanged: _onQuery,
                          textInputAction: TextInputAction.search,
                          style: AppText.body,
                          decoration: InputDecoration(
                            hintText: 'Cari catatan, kategori, akun, nominal',
                            prefixIcon: Icon(Icons.search, size: 20, color: c.inkMuted),
                            suffixIcon: IconButton(
                              tooltip: 'Tutup pencarian',
                              onPressed: _closeSearch,
                              icon: Icon(Icons.close, size: 20, color: c.ink),
                            ),
                            contentPadding: const EdgeInsets.symmetric(vertical: 13),
                            border: pill,
                            enabledBorder: pill,
                            focusedBorder: pill.copyWith(borderSide: BorderSide(color: c.primary, width: 1.5)),
                          ),
                        )
                      : Row(
                          children: [
                            Expanded(child: Text('Transaksi', style: AppText.title)),
                            IconButton(
                              tooltip: 'Pilih bulan',
                              onPressed: _pickMonth,
                              style: IconButton.styleFrom(backgroundColor: c.surface, fixedSize: const Size.square(46)),
                              icon: Icon(Icons.calendar_today_outlined, size: 20, color: c.ink),
                            ),
                            const SizedBox(width: AppSpace.tight),
                            // The round search button of the "E · Transaksi" artboard.
                            IconButton(
                              tooltip: 'Cari transaksi',
                              onPressed: () => setState(() => _searching = true),
                              style: IconButton.styleFrom(backgroundColor: c.surface, fixedSize: const Size.square(46)),
                              icon: Icon(Icons.search, size: 20, color: c.ink),
                            ),
                          ],
                        ),
                ),
                const SizedBox(height: 16),
                if (!_searching) ...[const QuickInputBar(), const SizedBox(height: 16)],
                Wrap(
                  spacing: AppSpace.tight,
                  runSpacing: AppSpace.tight,
                  children: [
                    if (month case final m?)
                      InputChip(
                        label: Text(DateFormat('MMMM yyyy', 'id_ID').format(m)),
                        selected: true,
                        showCheckmark: false,
                        labelStyle: AppText.label.copyWith(fontSize: 14, color: c.onPrimary, fontWeight: FontWeight.w500),
                        deleteIconColor: c.onPrimary,
                        deleteButtonTooltipMessage: 'Hapus filter bulan',
                        onPressed: _pickMonth,
                        onDeleted: () => _setMonth(null),
                      ),
                    for (final (type, label) in const [
                      (null, 'Semua'),
                      ('expense', 'Keluar'),
                      ('income', 'Masuk'),
                      ('transfer', 'Transfer'),
                    ])
                      ChoiceChip(
                        label: Text(label),
                        selected: _type == type,
                        showCheckmark: false,
                        labelStyle: AppText.label.copyWith(
                          fontSize: 14,
                          color: _type == type ? c.onPrimary : c.ink,
                          fontWeight: _type == type ? FontWeight.w500 : null,
                        ),
                        onSelected: (_) => setState(() => _type = type),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                if (!_searching) const NotificationInbox(),
                if (_query.isNotEmpty && rows != null && rows.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 10),
                    child: Text(
                      '${rows.length}${snap.data!.length == _searchLimit ? '+' : ''} transaksi cocok dengan "$_query"$inMonth',
                      style: AppText.label.copyWith(color: c.inkMuted),
                    ),
                  ),
                if (rows == null)
                  const Center(child: CircularProgressIndicator())
                else if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      _query.isNotEmpty
                          ? 'Tidak ada transaksi yang cocok dengan "$_query"$inMonth.'
                          : _type != null
                          ? 'Tidak ada transaksi jenis ini$inMonth.'
                          : month != null
                          ? 'Tidak ada transaksi$inMonth.'
                          : 'Belum ada transaksi. Tekan + untuk mencatat.',
                      textAlign: TextAlign.center,
                      style: AppText.body.copyWith(color: c.inkMuted),
                    ),
                  )
                else
                  for (final day in _byDay(rows)) _DayGroup(day),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Rows are newest first already, so each day is one run of consecutive rows.
  static List<List<Map<String, dynamic>>> _byDay(List<Map<String, dynamic>> rows) {
    final days = <List<Map<String, dynamic>>>[];
    DateTime? current;
    for (final r in rows) {
      final t = DateTime.parse(r['occurred_at'] as String).toLocal();
      final day = DateTime(t.year, t.month, t.day);
      if (day != current) days.add([]);
      current = day;
      days.last.add(r);
    }
    return days;
  }
}

class _DayGroup extends StatelessWidget {
  const _DayGroup(this.rows);

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final now = DateTime.now();
    final day = DateTime.parse(rows.first['occurred_at'] as String).toLocal();
    final diff = DateTime(now.year, now.month, now.day).difference(DateTime(day.year, day.month, day.day)).inDays;
    final title = switch (diff) {
      0 => 'Hari ini',
      1 => 'Kemarin',
      _ => DateFormat(day.year == now.year ? 'EEEE, d MMM' : 'EEEE, d MMM yyyy', 'id_ID').format(day),
    };
    // Net of the day; transfers only move money between own accounts.
    final net = rows.fold<int>(
      0,
      (sum, r) => sum + switch (r['type']) {
        'income' => r['amount'] as int,
        'expense' => -(r['amount'] as int),
        _ => 0,
      },
    );
    final time = DateFormat('HH.mm');
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(child: Text(title, style: AppText.bodyStrong)),
                if (net != 0)
                  Text(
                    '${net < 0 ? '−' : '+'}${formatAmount(net.abs())}',
                    style: AppText.label.copyWith(color: c.inkMuted),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.tight),
          Material(
            color: c.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  for (final (i, r) in rows.indexed) ...[
                    if (i > 0) const Divider(indent: 16, endIndent: 16),
                    RecordRow(
                      r,
                      detail: time.format(DateTime.parse(r['occurred_at'] as String).toLocal()),
                      withAccount: true,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- one record

/// One record in a list: what it was, its category, the amount and [detail] (a day or a time).
/// Tap edits it, long press deletes it.
class RecordRow extends StatelessWidget {
  const RecordRow(this.r, {super.key, required this.detail, this.withAccount = false});

  final Map<String, dynamic> r; // a records row joined with account_name, target_name, category_name/_icon
  final String detail;
  final bool withAccount; // always name the account (and labels), not only when nothing else fits

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final type = r['type'] as String;
    final category = type == 'transfer'
        ? 'Transfer ke ${r['target_name'] ?? '?'}'
        : (r['category_name'] as String?) ?? 'Tanpa kategori';
    final note = (r['note'] as String?)?.trim();
    final title = note == null || note.isEmpty ? category : note;
    final subtitle = [
      if (title != category) category,
      if (withAccount || title == category) ?r['account_name'],
      if (withAccount) ?r['label_names'],
    ].join(' · ');
    final amount = formatAmount(r['amount'] as int);
    final (text, color) = switch (type) {
      'income' => ('+$amount', c.income),
      'expense' => ('−$amount', c.ink),
      _ => (amount, c.ink),
    };
    final (bg, fg) = type == 'income' ? (c.primarySoft, c.primary) : (c.surfaceMuted, c.ink);
    return InkWell(
      onTap: () => showRecordForm(context, prefill: Prefill.fromRecord(r)),
      onLongPress: () {
        haptic(Haptic.click); // a hold always answers with a tick before its menu or dialog
        confirmDeleteRecord(context, r['id'] as String);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              child: Icon(categoryIcon(r['category_name'] as String?, type, r['category_icon'] as String?), size: 20, color: fg),
            ),
            const SizedBox(width: AppSpace.gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppText.caption.copyWith(color: c.inkMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.gap),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(text, style: AppText.amount.copyWith(color: color)),
                const SizedBox(height: 2),
                Text(detail, style: AppText.caption.copyWith(color: c.inkMuted)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- quick input (B2)

class QuickInputBar extends StatefulWidget {
  const QuickInputBar({super.key});

  @override
  State<QuickInputBar> createState() => _QuickInputBarState();
}

class _QuickInputBarState extends State<QuickInputBar> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false; // Gemini is reading the line, which takes a second or two

  @override
  void initState() {
    super.initState();
    quickInputRequests.addListener(_focusInput);
    // Opened by the widget or shortcut: Transaksi was just built, so the request is already in.
    if (quickInputRequests.value > _handled) WidgetsBinding.instance.addPostFrameCallback((_) => _focusInput());
  }

  static int _handled = 0; // the last request answered; the tab is rebuilt on every visit

  void _focusInput() {
    _handled = quickInputRequests.value;
    if (!mounted) return;
    _focus.requestFocus();
    // On a cold start the focus lands before Android gives the window input, so the keyboard
    // stays down; asking again once the window is up brings it.
    Future.delayed(const Duration(milliseconds: 400), () {
      if (_focus.hasFocus) SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await submitQuickInput(context, _text.text, onParsed: _text.clear);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    quickInputRequests.removeListener(_focusInput);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    const pill = OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(28)), borderSide: BorderSide.none);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text('Catat cepat', style: AppText.caption.copyWith(color: c.inkMuted)),
        ),
        TextField(
          controller: _text,
          focusNode: _focus,
          textInputAction: TextInputAction.send,
          onSubmitted: (_) => _submit(),
          style: AppText.body,
          decoration: InputDecoration(
            hintText: 'bakso 25rb pakai dana',
            fillColor: c.surface,
            contentPadding: const EdgeInsets.fromLTRB(20, 18, 6, 18),
            border: pill,
            enabledBorder: pill,
            focusedBorder: pill.copyWith(borderSide: BorderSide(color: c.primary, width: 1.5)),
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: IconButton.filled(
                tooltip: 'Simpan catatan cepat',
                onPressed: _busy ? null : _submit,
                style: IconButton.styleFrom(
                  backgroundColor: c.primary,
                  foregroundColor: c.onPrimary,
                  disabledBackgroundColor: c.primary,
                ),
                icon: _busy
                    ? SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: c.onPrimary),
                      )
                    : const Icon(Icons.arrow_forward, size: 20),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Saves one line of quick input ("bakso 25rb pakai dana", "makan 25rb parkir 5rb"), which may
/// hold several transactions. [onParsed] runs once the line is understood. With [review], and for
/// an entry with no category, a transfer, or an amount Gemini may have misread, the record form
/// opens instead of saving.
Future<void> submitQuickInput(
  BuildContext context,
  String text, {
  VoidCallback? onParsed,
  bool review = false,
}) async {
  final input = text.trim();
  if (input.isEmpty) return;
  final accounts = await db.getAll('SELECT id, name, provider, currency FROM accounts WHERE archived = 0');
  final categories = await db.getAll('SELECT id, name, type, keywords FROM categories WHERE archived = 0');
  if (!context.mounted) return;
  if (accounts.isEmpty) return showMessage(context, 'Buat akun dulu lewat Beranda, tombol Akun.');
  final entries =
      await _askGemini(input, accounts, categories) ??
      [?parseQuickInput(input, accounts: accounts, categories: categories)];
  if (!context.mounted) return;
  if (entries.isEmpty) return showMessage(context, 'Nominal tidak ditemukan. Contoh: bakso 25rb pakai dana');

  final defaultAccountId = await _lastAccountId(accounts);
  final labelIds = await resolveLabelIds(entries.first.labels); // "#liburan" creates the label if needed
  onParsed?.call();

  final saved = <({String id, QuickEntry entry, Map<String, dynamic> account})>[];
  final toCheck = <QuickEntry>[];
  for (final e in entries) {
    if (review || !e.sure || e.type == 'transfer' || e.categoryId == null) {
      toCheck.add(e);
      continue;
    }
    final account = accounts.firstWhere((a) => a['id'] == (e.accountId ?? defaultAccountId));
    final id = await insertRecord(
      accountId: account['id'] as String,
      type: e.type,
      amount: e.amount,
      currency: account['currency'] as String,
      occurredAt: e.date,
      categoryId: e.categoryId,
      note: e.note.isEmpty ? null : e.note,
      source: 'nlp',
      labelIds: labelIds,
    );
    saved.add((id: id, entry: e, account: account));
  }
  if (!context.mounted) return;
  if (saved.isNotEmpty) {
    final first = saved.first;
    showDone(
      context,
      'Tersimpan',
      saved.length == 1
          ? '${categories.firstWhere((c) => c['id'] == first.entry.categoryId)['name']} · '
                '${formatAmount(first.entry.amount)} · ${first.account['name']}'
          : '${saved.length} transaksi · ${formatAmount(saved.fold(0, (sum, s) => sum + s.entry.amount))}',
      onUndo: () => db.writeTransaction((tx) async {
        for (final s in saved) {
          await tx.execute('DELETE FROM records WHERE id = ?', [s.id]);
        }
      }),
    );
  }
  // Unknown words: let the user pick, which also teaches the keyword for next time.
  for (final e in toCheck) {
    if (!context.mounted) return;
    await showRecordForm(
      context,
      prefill: Prefill(
        amount: e.amount,
        type: e.type,
        accountId: e.accountId ?? defaultAccountId,
        transferAccountId: e.transferAccountId,
        categoryId: e.categoryId,
        note: e.note,
        date: e.date,
        source: 'nlp',
        labelIds: labelIds,
      ),
    );
  }
}

/// Gemini's reading of a quick-input line (supabase/functions/parse-quick-input), or null when it
/// can't answer in time (offline, over quota), so the offline rules take over.
Future<List<QuickEntry>?> _askGemini(
  String input,
  List<Map<String, dynamic>> accounts,
  List<Map<String, dynamic>> categories,
) async {
  try {
    final response = await supabase.functions
        .invoke(
          'parse-quick-input',
          body: {
            'text': input,
            'today': DateFormat('EEEE, d MMMM yyyy', 'id_ID').format(DateTime.now()),
            'accounts': [
              for (final a in accounts) {'id': a['id'], 'name': a['name'], 'provider': a['provider']},
            ],
            'categories': [
              for (final c in categories)
                {'id': c['id'], 'name': c['name'], 'type': c['type'], 'keywords': c['keywords']},
            ],
          },
        )
        .timeout(const Duration(seconds: 10)); // a cold start plus Gemini took about 8 s in testing
    final data = response.data;
    if (data is Map<String, dynamic>) return entriesFromAnswer(data, input, accounts: accounts, categories: categories);
    _log.warning('parse-quick-input answered ${data.runtimeType}');
  } on Exception catch (e) {
    _log.warning('Gemini unreachable, quick input falls back to the offline rules', e);
  }
  return null;
}

/// No account named: use the one from the latest record, so a daily wallet needs no typing.
Future<String> _lastAccountId(List<Map<String, dynamic>> accounts) async {
  final last = await db.getOptional('SELECT account_id FROM records ORDER BY created_at DESC LIMIT 1');
  return accounts.map((a) => a['id'] as String).where((id) => id == last?['account_id']).firstOrNull ??
      accounts.first['id'] as String;
}

// ---------------------------------------------------------------- notification inbox (B1)

class NotificationInbox extends StatefulWidget {
  const NotificationInbox({super.key});

  @override
  State<NotificationInbox> createState() => _NotificationInboxState();
}

class _NotificationInboxState extends State<NotificationInbox> with WidgetsBindingObserver {
  bool? _enabled;
  bool _expanded = false;
  List<Map<String, dynamic>> _rows = const [];
  List<Map<String, dynamic>> _categories = const [];
  final _gone = <String>{}; // swiped away, hidden until the query catches up
  final _subs = <StreamSubscription<void>>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subs.addAll([
      db.watch('SELECT * FROM inbox WHERE amount IS NOT NULL ORDER BY posted_at DESC').listen((rows) {
        if (mounted) setState(() => _rows = rows);
      }),
      db.watch('SELECT id, name, type, keywords FROM categories WHERE archived = 0').listen((rows) {
        if (mounted) setState(() => _categories = rows);
      }),
    ]);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    super.dispose();
  }

  // Returning from Android settings or from a bank app both arrive here.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final enabled = await notificationAccessEnabled();
    if (mounted) setState(() => _enabled = enabled);
    if (enabled) await importNotifications();
  }

  String _guessText(Map<String, dynamic> n) => '${n['title'] ?? ''}\n${n['text']}';

  String? _guess(Map<String, dynamic> n) =>
      n['type'] == null ? null : guessCategoryId(_guessText(n), n['type'] as String, _categories);

  Future<void> _open(Map<String, dynamic> n) => showRecordForm(
    context,
    prefill: Prefill(
      amount: n['amount'] as int,
      type: n['type'] as String?,
      provider: n['provider'] as String?,
      note: n['title'] as String?,
      date: DateTime.parse(n['posted_at'] as String).toLocal(),
      guessText: _guessText(n),
      source: 'notification',
      sourceRef: n['ref'] as String, // server-side unique index stops the same notification being recorded twice
      inboxId: n['id'] as String,
    ),
  );

  /// Saves straight away when the type, the account and the category are all clear; else opens
  /// the form so the user fills the gap. Returns whether it saved.
  Future<bool> _save(Map<String, dynamic> n) async {
    final type = n['type'] as String?;
    final categoryId = _guess(n);
    final accounts = await db.getAll(
      'SELECT id, name, currency FROM accounts WHERE archived = 0 AND provider = ?',
      [n['provider']],
    );
    if (type == null || categoryId == null || accounts.length != 1) {
      if (mounted) await _open(n);
      return false;
    }
    final account = accounts.single;
    final id = await insertRecord(
      accountId: account['id'] as String,
      type: type,
      amount: n['amount'] as int,
      currency: account['currency'] as String,
      occurredAt: DateTime.parse(n['posted_at'] as String).toLocal(),
      categoryId: categoryId,
      note: n['title'] as String?,
      source: 'notification',
      sourceRef: n['ref'] as String,
      inboxId: n['id'] as String,
    );
    if (mounted) {
      final category = _categories.firstWhere((c) => c['id'] == categoryId)['name'];
      showDone(
        context,
        'Tersimpan',
        '$category · ${formatAmount(n['amount'] as int)} · ${account['name']}',
        onUndo: () => _restore(n, deleteRecordId: id),
      );
    }
    return true;
  }

  Future<void> _ignore(Map<String, dynamic> n) async {
    await db.execute('DELETE FROM inbox WHERE id = ?', [n['id']]);
    if (mounted) {
      showDone(context, 'Diabaikan', 'Notifikasi ${formatAmount(n['amount'] as int)}', onUndo: () => _restore(n));
    }
  }

  /// Undo: the notification goes back to the list, and the record made from it is removed.
  Future<void> _restore(Map<String, dynamic> n, {String? deleteRecordId}) async {
    await db.writeTransaction((tx) async {
      if (deleteRecordId != null) await tx.execute('DELETE FROM records WHERE id = ?', [deleteRecordId]);
      await tx.execute(
        'INSERT INTO inbox (id, ref, package, provider, title, text, amount, type, posted_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          n['id'],
          n['ref'],
          n['package'],
          n['provider'],
          n['title'],
          n['text'],
          n['amount'],
          n['type'],
          n['posted_at'],
        ],
      );
    });
    if (mounted) setState(() => _gone.remove(n['id']));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    if (_enabled == null) return const SizedBox.shrink();
    if (_enabled == false) {
      return Container(
        margin: const EdgeInsets.only(bottom: AppSpace.section),
        padding: const EdgeInsets.all(AppSpace.card),
        decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(AppRadius.card)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Catat otomatis dari notifikasi bank & e-wallet', style: AppText.bodyStrong),
            const SizedBox(height: 4),
            Text(
              'Hanya notifikasi aplikasi keuangan yang dibaca. Isinya tetap di HP ini.',
              style: AppText.caption.copyWith(color: c.onPrimarySoft),
            ),
            const SizedBox(height: AppSpace.gap),
            FilledButton(onPressed: openNotificationAccessSettings, child: const Text('Aktifkan')),
          ],
        ),
      );
    }
    final rows = _rows.where((n) => !_gone.contains(n['id'])).toList();
    if (rows.isEmpty) return const SizedBox.shrink();
    const collapsed = 3;
    final shown = _expanded ? rows : rows.take(collapsed).toList();
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.section),
      padding: const EdgeInsets.all(AppSpace.card),
      decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(AppRadius.card)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Perlu dicek (${rows.length})', style: AppText.bodyStrong)),
              Icon(Icons.swap_horiz, size: 14, color: c.onPrimarySoft),
              const SizedBox(width: 4),
              Text('geser untuk memilih', style: AppText.caption.copyWith(color: c.onPrimarySoft)),
            ],
          ),
          for (final n in shown) ...[
            const SizedBox(height: AppSpace.tight),
            _InboxItem(
              n,
              categoryName: _categories.where((x) => x['id'] == _guess(n)).firstOrNull?['name'] as String?,
              onOpen: () => _open(n),
              onSave: () async {
                final saved = await _save(n);
                if (saved && mounted) setState(() => _gone.add(n['id'] as String));
              },
              onIgnore: () {
                setState(() => _gone.add(n['id'] as String));
                unawaited(_ignore(n));
              },
              confirmSave: () => _save(n),
              onSaved: () => setState(() => _gone.add(n['id'] as String)),
            ),
          ],
          if (rows.length > collapsed)
            TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? 'Tampilkan lebih sedikit' : 'Lihat ${rows.length - collapsed} lainnya'),
            ),
          const SizedBox(height: 4),
          Text(
            'Ketuk kartu untuk mengubah kategori atau akun sebelum disimpan.',
            style: AppText.caption.copyWith(color: c.onPrimarySoft),
          ),
        ],
      ),
    );
  }
}

/// One detected notification. Swipe right saves, swipe left ignores; the ⋯ menu does the same.
class _InboxItem extends StatelessWidget {
  const _InboxItem(
    this.n, {
    required this.categoryName,
    required this.onOpen,
    required this.onSave,
    required this.onIgnore,
    required this.confirmSave,
    required this.onSaved,
  });

  final Map<String, dynamic> n;
  final String? categoryName; // the guess, null when nothing fits
  final VoidCallback onOpen;
  final VoidCallback onSave; // from the menu
  final VoidCallback onIgnore;
  final Future<bool> Function() confirmSave; // a swipe saves, or snaps back when the form opened
  final VoidCallback onSaved; // after a swipe saved: hide the card before the query catches up

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final provider = accountPresets.where((p) => p.provider == n['provider']).map((p) => p.name).firstOrNull;
    final amount = formatAmount(n['amount'] as int);
    final sign = switch (n['type']) {
      'income' => '+',
      'expense' => '−',
      _ => '',
    };
    final radius = BorderRadius.circular(18);
    Widget behind(Color color, Alignment side, List<Widget> children) => Container(
      decoration: BoxDecoration(color: color, borderRadius: radius),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: side,
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
    return Dismissible(
      key: ValueKey(n['id']),
      background: behind(c.primary, Alignment.centerLeft, [
        Icon(Icons.check, color: c.onPrimary),
        const SizedBox(width: 8),
        Text('Simpan', style: AppText.bodyStrong.copyWith(fontSize: 14, color: c.onPrimary)),
      ]),
      secondaryBackground: behind(c.surfaceMuted, Alignment.centerRight, [
        Text('Abaikan', style: AppText.bodyStrong.copyWith(fontSize: 14, color: c.ink)),
        const SizedBox(width: 8),
        Icon(Icons.close, color: c.ink),
      ]),
      confirmDismiss: (direction) async => direction == DismissDirection.endToStart || await confirmSave(),
      onDismissed: (direction) => direction == DismissDirection.endToStart ? onIgnore() : onSaved(),
      child: Material(
        color: c.surface,
        borderRadius: radius,
        child: InkWell(
          onTap: onOpen,
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: c.surfaceMuted, shape: BoxShape.circle),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      provider ?? '?',
                      style: AppText.caption.copyWith(fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$sign$amount', style: AppText.amount),
                      const SizedBox(height: 2),
                      Text(
                        [categoryName ?? 'Pilih kategori', n['text']].join(' · '),
                        style: AppText.caption.copyWith(color: c.inkMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<bool>(
                  tooltip: 'Pilihan lain',
                  icon: Icon(Icons.more_horiz, color: c.inkMuted),
                  onSelected: (save) => save ? onSave() : onIgnore(),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: true, child: Text('Simpan')),
                    PopupMenuItem(value: false, child: Text('Abaikan')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
