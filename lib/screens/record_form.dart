import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

import '../categorize.dart';
import '../db.dart';
import '../money.dart';
import '../quick_input.dart';
import '../receipt_items.dart';
import '../theme.dart';
import '../ui.dart';
import 'accounts_tab.dart';
import 'labels_page.dart';

/// Returns true when the record was deleted.
Future<bool> confirmDeleteRecord(BuildContext context, String id) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Hapus transaksi?'),
      // ponytail: deleting a paid bill's record does not move the bill's due date back; skip it by hand.
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Hapus')),
      ],
    ),
  );
  if (ok != true) return false;
  haptic(Haptic.heavy);
  await db.execute('DELETE FROM records WHERE id = ?', [id]);
  return true;
}

/// Values to start the record form with: a detected notification, quick input, a bill, a goal,
/// or an existing record to edit ([recordId]).
class Prefill {
  factory Prefill.fromRecord(Map<String, dynamic> r) => Prefill(
    recordId: r['id'] as String,
    amount: r['amount'] as int,
    type: r['type'] as String,
    accountId: r['account_id'] as String,
    categoryId: r['category_id'] as String?,
    transferAccountId: r['transfer_account_id'] as String?,
    note: r['note'] as String?,
    date: DateTime.parse(r['occurred_at'] as String).toLocal(),
    source: (r['source'] as String?) ?? 'manual',
    labelIds: labelIdsOf(r['label_ids']),
    items: itemsOf(r['items']),
  );

  const Prefill({
    this.recordId,
    this.amount,
    this.type,
    this.accountId,
    this.provider,
    this.categoryId,
    this.note,
    this.date,
    this.guessText,
    this.source = 'manual',
    this.sourceRef,
    this.inboxId,
    this.plannedPaymentId,
    this.transferAccountId,
    this.nextDue,
    this.labelIds = const [],
    this.items = const [],
  });

  final String? recordId; // edit this record instead of inserting a new one
  final int? amount;
  final String? type;
  final String? accountId;
  final String? provider; // picks the account with this preset when accountId is null
  final String? categoryId;
  final String? note;
  final DateTime? date;
  final String? guessText; // text to guess the category from when categoryId is null
  final String source;
  final String? sourceRef;
  final String? inboxId; // inbox row to remove once the record is saved
  final String? plannedPaymentId; // bill being paid; moves on to [nextDue] once saved
  final DateTime? nextDue;
  final String? transferAccountId; // transfer into this account, e.g. a saving goal's account
  final List<String> labelIds;
  final List<ReceiptItem> items; // a scanned receipt's lines
}

/// With [scanReceipt] the form opens straight on the receipt photo choice.
Future<void> showRecordForm(BuildContext context, {Prefill? prefill, bool scanReceipt = false}) async {
  // Archived accounts and categories stay selectable when the record being edited uses them.
  final accounts = await db.getAll(
    '''
    SELECT a.id, a.name, a.currency, a.provider, b.balance
    FROM accounts a JOIN ($accountBalancesSql) b ON b.id = a.id
    WHERE a.archived = 0 OR a.id IN (?, ?) ORDER BY a.name''',
    [prefill?.accountId, prefill?.transferAccountId],
  );
  if (!context.mounted) return;
  if (accounts.isEmpty) return askForAccount(context);
  // Most used first, so the quick chips under the form hold the likely picks. The records are
  // counted in one pass; a count per category would read them all once for each category.
  final categories = await db.getAll(
    '''
    SELECT c.id, c.name, c.type, c.keywords, c.icon FROM categories c
    LEFT JOIN (SELECT category_id, COUNT(*) AS n FROM records GROUP BY category_id) u ON u.category_id = c.id
    WHERE c.archived = 0 OR c.id = ?
    ORDER BY COALESCE(u.n, 0) DESC, c.name''',
    [prefill?.categoryId],
  );
  final labels = await db.getAll('SELECT id, name FROM labels ORDER BY name COLLATE NOCASE');
  // Past notes for the Catatan suggestions, the most used (then the latest) first.
  final notes = await db.getAll('''
    SELECT MIN(note) AS note FROM records WHERE note IS NOT NULL AND trim(note) != ''
    GROUP BY lower(trim(note)) ORDER BY COUNT(*) DESC, MAX(occurred_at) DESC LIMIT 300''');
  if (!context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => RecordForm(
        accounts: accounts,
        categories: categories,
        labels: labels,
        notes: [for (final n in notes) (n['note'] as String).trim()],
        prefill: prefill,
        scanReceipt: scanReceipt,
      ),
    ),
  );
}

class RecordForm extends StatefulWidget {
  const RecordForm({
    super.key,
    required this.accounts,
    required this.categories,
    required this.labels,
    this.notes = const [],
    this.prefill,
    this.scanReceipt = false,
  });

  final bool scanReceipt;

  final List<Map<String, dynamic>> accounts;
  final List<Map<String, dynamic>> categories;
  final List<Map<String, dynamic>> labels;
  final List<String> notes; // past notes, most used first: the Catatan suggestions
  final Prefill? prefill;

  @override
  State<RecordForm> createState() => _RecordFormState();
}

class _RecordFormState extends State<RecordForm> {
  final _quick = TextEditingController();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _fee = TextEditingController(); // a transfer's admin fee, saved as its own expense
  final _amountFocus = FocusNode();
  final _noteFocus = FocusNode();
  final _feeFocus = FocusNode();
  List<String> _quickLabels = const []; // "#liburan" typed in the quick field, created on save
  String _type = 'expense';
  late String _accountId = widget.accounts.first['id'] as String;
  String? _targetId;
  String? _categoryId;
  DateTime _date = DateTime.now();
  late Set<String> _labelIds = {...?widget.prefill?.labelIds};
  late List<ReceiptItem> _items = [...?widget.prefill?.items];
  bool _allItems = false; // a long receipt shows its first few lines until asked for the rest

  @override
  void initState() {
    super.initState();
    if (widget.scanReceipt) WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_scanReceipt()));
    final p = widget.prefill;
    if (p == null) return;
    if (p.amount != null) _amount.text = NumberFormat.decimalPattern('id_ID').format(p.amount! / 100);
    _type = p.type ?? 'expense';
    _note.text = p.note ?? '';
    _date = p.date ?? _date;
    final account = widget.accounts
        .where((a) => p.accountId != null ? a['id'] == p.accountId : p.provider != null && a['provider'] == p.provider)
        .firstOrNull;
    if (account != null) _accountId = account['id'] as String;
    if (p.transferAccountId case final target?) {
      _targetId = target;
      // Pay in from any other account; the form refuses a transfer to the same account.
      final other = widget.accounts.where((a) => a['id'] != target).firstOrNull;
      if (_accountId == target && other != null) _accountId = other['id'] as String;
    }
    _categoryId = p.categoryId ?? guessCategoryId(p.guessText ?? _note.text, _type, widget.categories);
    if (_editing) {
      // The saved category is the user's choice: editing the note must not replace it.
      _categoryPicked = p.categoryId != null;
      _originalCategoryId = p.categoryId;
    }
  }

  bool get _editing => widget.prefill?.recordId != null;
  String? _originalCategoryId;

  // Typing a note fills an empty category, e.g. "bakso" -> Makan & Minum. Never overrides a choice.
  bool _categoryPicked = false;

  void _onNoteChanged(String note) {
    _touched.add('note');
    if (_categoryPicked || _type == 'transfer') return;
    final guess = guessCategoryId(note, _type, widget.categories);
    if (guess != _categoryId) setState(() => _categoryId = guess);
  }

  // Only for a fresh record that nothing filled in yet (not an edit, a notification or a bill).
  late final bool _showQuick = !_editing && widget.prefill?.amount == null;

  final _touched = <String>{}; // fields the user changed by hand: quick input never writes over them
  ({String type, String accountId, DateTime date})? _blank; // what quick input replaced; null until it fills
  List<QuickEntry> _entries = const []; // what Gemini read from the line
  bool _byAi = false; // the fields hold Gemini's reading
  bool _asking = false; // Gemini is reading the line
  String? _hint; // why the plain rules may be wrong; the user decides whether to ask AI

  void _fill(QuickEntry e) {
    _blank ??= (type: _type, accountId: _accountId, date: _date);
    if (!_touched.contains('amount')) _amount.text = NumberFormat.decimalPattern('id_ID').format(e.amount / 100);
    if (!_touched.contains('type')) _type = e.type;
    if (!_touched.contains('note')) _note.text = e.note;
    if (!_touched.contains('date')) _date = e.date;
    if (!_touched.contains('account') && e.accountId != null) _accountId = e.accountId!;
    if (!_touched.contains('target') && e.transferAccountId != null) _targetId = e.transferAccountId;
    if (!_categoryPicked) {
      _categoryId = _type == 'transfer'
          ? null
          : e.type == _type
          ? e.categoryId
          : guessCategoryId(_note.text, _type, widget.categories);
    }
    _quickLabels = e.labels;
  }

  /// The line no longer holds an amount: takes back what it filled, and leaves what the user set.
  void _clearFilled() {
    final blank = _blank;
    if (blank == null) return;
    _blank = null;
    if (!_touched.contains('amount')) _amount.clear();
    if (!_touched.contains('type')) _type = blank.type;
    if (!_touched.contains('note')) _note.clear();
    if (!_touched.contains('date')) _date = blank.date;
    if (!_touched.contains('account')) _accountId = blank.accountId;
    if (!_touched.contains('target')) _targetId = null;
    if (!_categoryPicked) _categoryId = null;
    _quickLabels = const [];
  }

  /// The quick field fills the form from the plain rules as the user types: "bakso 25rb pakai gopay".
  void _onQuickChanged(String text) {
    final e = parseQuickInput(text, accounts: widget.accounts, categories: widget.categories);
    setState(() {
      _entries = const [];
      _byAi = false;
      _hint = quickInputHint(text, e);
      if (e == null) {
        _clearFilled();
      } else {
        _fill(e);
      }
    });
  }

  /// The arrow or the keyboard's send: Gemini reads what the plain rules can't, such as a transfer.
  Future<void> _askAi() async {
    final input = _quick.text.trim();
    if (input.isEmpty || _asking || _reading) return;
    setState(() => _asking = true);
    try {
      final entries = await _askGemini(input, widget.accounts, widget.categories);
      if (!mounted || _quick.text.trim() != input) return; // typing on has replaced this line
      if (entries == null) return showMessage(context, 'AI tidak terjangkau. Kolom tetap terisi dari aturan dasar.');
      if (entries.isEmpty) return showMessage(context, 'Nominal tidak ditemukan. Contoh: bakso 25rb pakai gopay');
      setState(() {
        _fill(entries.first);
        _entries = entries;
        _byAi = true;
        _hint = null;
      });
      FocusManager.instance.primaryFocus?.unfocus(); // show the filled form, not the keyboard
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  /// A line with several transactions: saves them all, the way Catat cepat does.
  Future<void> _saveEntries() async {
    final root = Navigator.of(context).context; // outlives this screen, for the "Tersimpan" bar
    Navigator.pop(context);
    await saveQuickEntries(root, _entries, widget.accounts, widget.categories);
  }

  bool _reading = false; // Gemini is reading a receipt photo

  /// The camera button of the quick field: a receipt photo fills the form for a check before saving.
  Future<void> _scanReceipt() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Foto struk'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Pilih dari galeri'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    // 1600 px keeps small print readable at about 300 kB, well inside the free Gemini quota.
    final photo = await ImagePicker().pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 80);
    if (photo == null || !mounted) return;
    setState(() => _reading = true);
    try {
      final r = await _readReceipt(await photo.readAsBytes(), widget.accounts, widget.categories);
      if (!mounted) return;
      if (r == null) {
        return showMessage(context, 'Tidak bisa membaca struk sekarang (offline atau kuota habis). Isi manual dulu.');
      }
      final amount = (r['amount'] as num?)?.toInt() ?? 0;
      if (amount <= 0) return showMessage(context, 'Total struk tidak terbaca. Coba foto lebih dekat dan terang.');
      String? known(Object? id, List<Map<String, dynamic>> rows) =>
          rows.any((x) => x['id'] == id) ? id as String : null;
      final now = DateTime.now();
      final daysAgo = ((r['days_ago'] as num?)?.toInt() ?? 0).clamp(0, 366);
      setState(() {
        _amount.text = NumberFormat.decimalPattern('id_ID').format(amount);
        _type = 'expense';
        _note.text = (r['note'] as String?)?.trim() ?? '';
        // The printed time when there is one ("14:05"), else now.
        final time = RegExp(r'^([01]?\d|2[0-3])[:.]([0-5]\d)$').firstMatch((r['time'] as String?)?.trim() ?? '');
        _date = DateTime(
          now.year,
          now.month,
          now.day - daysAgo,
          time == null ? now.hour : int.parse(time[1]!),
          time == null ? now.minute : int.parse(time[2]!),
        );
        if (known(r['account_id'], widget.accounts) case final id?) _accountId = id;
        _categoryId =
            known(r['category_id'], widget.categories) ?? guessCategoryId(_note.text, 'expense', widget.categories);
        _categoryPicked = false;
        _items = itemsFromReceipt(r['items']);
        _allItems = false;
        _byAi = true;
      });
      FocusManager.instance.primaryFocus?.unfocus(); // show the filled form, not the keyboard
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  void _pickCategory(String? id) {
    FocusManager.instance.primaryFocus?.unfocus(); // a chip takes no focus, so the keyboard would stay up
    if (id != _categoryId) haptic(Haptic.tick);
    setState(() {
      _categoryId = id;
      _categoryPicked = true;
      _hint = null;
    });
  }

  List<(String, String, String?)> _accountOptions({String? except}) => [
    for (final a in widget.accounts)
      if (a['id'] != except) (a['id'] as String, a['name'] as String, formatAmount(a['balance'] as int)),
  ];

  Future<void> _pickDate() async {
    final day = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (day == null || !mounted) return;
    _touched.add('date');
    setState(() => _date = DateTime(day.year, day.month, day.day, _date.hour, _date.minute));
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_date));
    if (t == null || !mounted) return;
    _touched.add('date');
    setState(() => _date = DateTime(_date.year, _date.month, _date.day, t.hour, t.minute));
  }

  String get _dayText {
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day).difference(DateTime(_date.year, _date.month, _date.day)).inDays;
    final day = switch (days) {
      0 => 'Hari ini, ${DateFormat('d MMM', 'id_ID').format(_date)}',
      1 => 'Kemarin, ${DateFormat('d MMM', 'id_ID').format(_date)}',
      _ => DateFormat('EEEE, d MMM yyyy', 'id_ID').format(_date),
    };
    return day;
  }

  Future<void> _save() async {
    final amount = parseAmount(_amount.text);
    if (amount == null) return showMessage(context, 'Nominal tidak valid. Contoh: 25.000');
    if (_type == 'transfer' && (_targetId == null || _targetId == _accountId)) {
      return showMessage(context, 'Pilih akun tujuan yang berbeda.');
    }
    final fee = _type == 'transfer' && !_editing && _fee.text.trim().isNotEmpty ? parseAmount(_fee.text) : null;
    if (_type == 'transfer' && !_editing && _fee.text.trim().isNotEmpty && fee == null) {
      return showMessage(context, 'Biaya admin tidak valid. Contoh: 1.000');
    }
    final currency = widget.accounts.firstWhere((a) => a['id'] == _accountId)['currency'] as String;
    final p = widget.prefill;
    final note = _note.text.trim();
    if (_quickLabels.isNotEmpty) _labelIds = {..._labelIds, ...await resolveLabelIds(_quickLabels)};
    final transfer = _type == 'transfer';
    final categoryId = transfer ? null : _categoryId;
    final transferAccountId = transfer ? _targetId : null;
    // ponytail: same-currency transfers only; ask for the received amount when currencies differ.
    final transferAmount = transfer ? amount : null;
    if (p?.recordId case final id?) {
      await updateRecord(
        id,
        accountId: _accountId,
        type: _type,
        amount: amount,
        currency: currency,
        occurredAt: _date,
        categoryId: categoryId,
        transferAccountId: transferAccountId,
        transferAmount: transferAmount,
        note: note.isEmpty ? null : note,
        labelIds: [..._labelIds],
        items: encodeItems(_items),
      );
    } else {
      await insertRecord(
        accountId: _accountId,
        type: _type,
        amount: amount,
        currency: currency,
        occurredAt: _date,
        categoryId: categoryId,
        transferAccountId: transferAccountId,
        transferAmount: transferAmount,
        note: note.isEmpty ? null : note,
        source: p?.source ?? 'manual',
        sourceRef: p?.sourceRef,
        inboxId: p?.inboxId,
        plannedPaymentId: p?.plannedPaymentId,
        nextDue: p?.nextDue,
        labelIds: [..._labelIds],
        items: encodeItems(_items),
      );
      // The fee leaves the source account too, but as spending, so Laporan counts it.
      if (fee != null) {
        await insertRecord(
          accountId: _accountId,
          type: 'expense',
          amount: fee,
          currency: currency,
          occurredAt: _date,
          categoryId: widget.categories
              .where((x) => x['type'] == 'expense' && x['name'] == 'Lainnya')
              .firstOrNull?['id'] as String?,
          note: 'Biaya admin transfer',
        );
      }
    }
    // Learn only from notes the user typed (manual or quick input): a notification title like
    // "Pembayaran berhasil" or a bill name says nothing new. When editing, only an actual change of
    // category teaches anything. Skip when the keywords already led to this category.
    final picked = categoryId;
    final typedNote = const {'manual', 'nlp'}.contains(p?.source ?? 'manual');
    final changed = !_editing || picked != _originalCategoryId;
    if (_categoryPicked && picked != null && typedNote && changed && note.isNotEmpty) {
      if (guessCategoryId(note, _type, widget.categories) != picked) await learnKeyword(note, picked);
    }
    haptic(Haptic.click); // saved
    if (mounted) Navigator.pop(context);
  }

  /// Fixes a line the receipt reading got wrong, or drops it.
  Future<void> _editItem(int index) async {
    final result = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ItemSheet(item: _items[index]),
    );
    if (!mounted || result == null) return;
    setState(() {
      if (result is ReceiptItem) {
        _items[index] = result;
      } else {
        _items.removeAt(index);
      }
    });
  }

  Future<void> _delete() async {
    if (await confirmDeleteRecord(context, widget.prefill!.recordId!) && mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _quick.dispose();
    _amount.dispose();
    _note.dispose();
    _fee.dispose();
    _amountFocus.dispose();
    _noteFocus.dispose();
    _feeFocus.dispose();
    super.dispose();
  }

  /// The receipt's lines, then what they leave out of the total (tax, service, a bill discount).
  Widget _itemsCard(AppColors c) {
    const few = 3;
    final shown = _allItems || _items.length <= few + 1 ? _items.length : few;
    final gap = itemsGap(_items, parseAmount(_amount.text) ?? 0);
    return FormCard(
      children: [
        for (var i = 0; i < shown; i++)
          FormRow(
            icon: Icons.receipt_long_outlined,
            label: '${_items[i].qty} ×',
            value: _items[i].name,
            trailing: Text(formatAmount(_items[i].amount)),
            onTap: () => _editItem(i),
          ),
        if (shown < _items.length)
          TextButton(
            onPressed: () => setState(() => _allItems = true),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            child: Text('Lihat semua ${_items.length} item'),
          ),
        if (gap != 0 && parseAmount(_amount.text) != null)
          FormRow(
            icon: Icons.percent,
            label: 'Selisih dari total',
            value: gap > 0 ? 'Pajak & servis' : 'Diskon',
            trailing: Text('${gap > 0 ? '+' : '-'}${formatAmount(gap.abs())}'),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final transfer = _type == 'transfer';
    final categories = widget.categories.where((x) => x['type'] == _type).toList();
    String? nameOf(List<Map<String, dynamic>> rows, String? id) =>
        rows.where((x) => x['id'] == id).firstOrNull?['name'] as String?;
    final account = widget.accounts.firstWhere((a) => a['id'] == _accountId);
    final target = widget.accounts.where((a) => a['id'] == _targetId).firstOrNull;
    final category = nameOf(widget.categories, _categoryId);
    // The few most used, plus the current pick when it is further down the list.
    final chips = [
      ...categories.take(6),
      ...categories.skip(6).where((x) => x['id'] == _categoryId),
    ];
    return Scaffold(
      appBar: pageAppBar(context, _editing ? 'Ubah transaksi' : 'Catat transaksi'),
      // A tap on empty form space, or a drag, puts the keyboard away (issue #1).
      body: GestureDetector(
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 20),
          children: [
            if (_showQuick) ...[
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(
                  _reading || _asking
                      ? 'AI sedang membaca…'
                      : _byAi
                      ? 'Terisi oleh AI, cek sebelum simpan'
                      : 'Isi otomatis. Tekan icon AI kalau hasilnya kurang tepat',
                  style: AppText.caption.copyWith(color: c.inkMuted),
                ),
              ),
              TextField(
                controller: _quick,
                autofocus: !widget.scanReceipt,
                textInputAction: TextInputAction.send,
                onChanged: _onQuickChanged,
                onSubmitted: (_) => unawaited(_askAi()),
                style: AppText.body,
                decoration: InputDecoration(
                  hintText: 'bakso 25rb pakai gopay',
                  fillColor: c.primarySoft,
                  prefixIcon: Icon(Icons.bolt, size: 20, color: c.primary),
                  suffixIcon: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: QuickFieldAction(
                      busy: _reading || _asking,
                      hasText: _quick.text.trim().isNotEmpty,
                      sendTooltip: 'Baca dengan AI',
                      sendIcon: Icons.auto_awesome,
                      onSend: _askAi,
                      onCamera: _scanReceipt,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 16),
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(26)),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(26)),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: const BorderRadius.all(Radius.circular(26)),
                    borderSide: BorderSide(color: c.primary, width: 1.5),
                  ),
                ),
              ),
              if (_hint case final hint? when !_asking && !_reading) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(hint, style: AppText.caption.copyWith(color: c.primary, fontWeight: FontWeight.w500)),
                ),
              ],
              if (_entries.length > 1) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                  decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.tile)),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Ada ${_entries.length} transaksi di kalimat ini',
                              style: AppText.bodyStrong.copyWith(fontSize: 14),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Di sini hanya yang pertama terisi',
                              style: AppText.caption.copyWith(color: c.inkMuted),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpace.gap),
                      FilledButton(
                        onPressed: _saveEntries,
                        style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                        child: Text(_entries.length == 2 ? 'Catat keduanya' : 'Catat semua'),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 18),
            ],
            PillSwitch(
              options: const [('expense', 'Keluar'), ('income', 'Masuk'), ('transfer', 'Transfer')],
              value: _type,
              onChanged: (type) => setState(() {
                _touched.add('type');
                _hint = null;
                _type = type;
                _categoryPicked = false;
                _categoryId = type == 'transfer' ? null : guessCategoryId(_note.text, type, widget.categories);
              }),
            ),
            const SizedBox(height: 8),
            // The whole block, not just the digits, takes a tap: an empty field is one "0" wide.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _amount.selection = TextSelection.collapsed(offset: _amount.text.length);
                _amountFocus.requestFocus();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  children: [
                    Text('Nominal', style: AppText.label.copyWith(color: c.inkMuted)),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          'Rp',
                          style: AppText.title.copyWith(fontSize: 22, fontWeight: FontWeight.w500, color: c.inkMuted),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: IntrinsicWidth(
                            child: TextField(
                              controller: _amount,
                              focusNode: _amountFocus,
                              autofocus: !_showQuick && !_editing && _amount.text.isEmpty,
                              onChanged: (_) => _touched.add('amount'),
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: const [AmountInputFormatter()],
                              style: AppText.amountXl.copyWith(color: c.ink),
                              // The hint takes the digits' size, not the theme's body text.
                              decoration: bareField('0').copyWith(hintStyle: AppText.amountXl.copyWith(color: c.inkMuted)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            FormCard(
              children: [
                FormRow(
                  icon: Icons.edit_outlined,
                  label: 'Catatan',
                  focusNode: _noteFocus,
                  // Earlier notes that continue what is typed ("ayam" -> "Ayam Goreng") drop down
                  // under the row; picking one fills the note and guesses its category.
                  child: LayoutBuilder(
                    builder: (context, box) => RawAutocomplete<String>(
                      textEditingController: _note,
                      focusNode: _noteFocus,
                      optionsBuilder: (value) => noteSuggestions(widget.notes, value.text),
                      onSelected: (note) {
                        haptic(Haptic.tick);
                        _onNoteChanged(note);
                      },
                      fieldViewBuilder: (context, controller, focusNode, _) => TextField(
                        controller: controller,
                        focusNode: focusNode,
                        onChanged: _onNoteChanged,
                        style: AppText.body.copyWith(fontWeight: FontWeight.w500),
                        decoration: bareField('contoh: bakso, bensin, token PLN'),
                      ),
                      optionsViewBuilder: (context, onSelected, options) => Align(
                        alignment: Alignment.topLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Material(
                            color: c.surface,
                            elevation: 6,
                            shadowColor: Colors.black26,
                            borderRadius: BorderRadius.circular(AppRadius.input),
                            clipBehavior: Clip.antiAlias,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: box.maxWidth, maxHeight: 260),
                              child: ListView(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                shrinkWrap: true,
                                children: [
                                  for (final note in options)
                                    InkWell(
                                      onTap: () => onSelected(note),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                        child: Row(
                                          children: [
                                            Icon(Icons.history, size: 18, color: c.inkMuted),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                note,
                                                style: AppText.body,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!transfer)
                  FormRow(
                    icon: categoryIcon(
                      category,
                      _type,
                      widget.categories.where((x) => x['id'] == _categoryId).firstOrNull?['icon'] as String?,
                    ),
                    strong: true,
                    label: 'Kategori',
                    value: category ?? 'Pilih kategori',
                    badge: category != null && !_categoryPicked ? 'ditebak dari catatan' : null,
                    onTap: () async {
                      final id = await chooseOne(context, 'Kategori', [
                        for (final x in categories) (x['id'] as String, x['name'] as String, null),
                      ], _categoryId);
                      if (id != null) _pickCategory(id);
                    },
                  ),
                FormRow(
                  icon: Icons.account_balance_wallet_outlined,
                  label: transfer ? 'Dari akun' : 'Akun',
                  value: account['name'] as String,
                  trailing: Text(formatAmount(account['balance'] as int)),
                  onTap: () async {
                    final id = await chooseOne(context, transfer ? 'Dari akun' : 'Akun', _accountOptions(), _accountId);
                    if (id != null) {
                      setState(() {
                        _touched.add('account');
                        _accountId = id;
                        if (_targetId == id) _targetId = null;
                      });
                    }
                  },
                ),
                if (transfer)
                  FormRow(
                    icon: Icons.swap_horiz,
                    strong: true,
                    label: 'Ke akun',
                    value: target?['name'] as String? ?? 'Pilih akun tujuan',
                    trailing: target == null ? null : Text(formatAmount(target['balance'] as int)),
                    onTap: () async {
                      final id = await chooseOne(context, 'Ke akun', _accountOptions(except: _accountId), _targetId);
                      if (id != null) {
                        _touched.add('target');
                        setState(() => _targetId = id);
                      }
                    },
                  ),
                // ponytail: new transfers only; editing a transfer leaves its fee record alone.
                if (transfer && !_editing)
                  FormRow(
                    icon: Icons.receipt_long_outlined,
                    label: 'Biaya admin',
                    focusNode: _feeFocus,
                    child: TextField(
                      controller: _fee,
                      focusNode: _feeFocus,
                      keyboardType: TextInputType.number,
                      inputFormatters: const [AmountInputFormatter()],
                      style: AppText.body.copyWith(fontWeight: FontWeight.w500),
                      decoration: bareField('0'),
                    ),
                  ),
                // The day opens the calendar, the time pill the clock, each on its own.
                FormRow(
                  icon: Icons.calendar_today_outlined,
                  label: 'Tanggal',
                  onTap: _pickDate,
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          _dayText,
                          style: AppText.body.copyWith(fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Material(
                        color: c.primarySoft,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          onTap: _pickTime,
                          borderRadius: BorderRadius.circular(14),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.schedule, size: 16, color: c.primary),
                                const SizedBox(width: 4),
                                Text(
                                  DateFormat('HH.mm').format(_date),
                                  semanticsLabel: 'Jam ${DateFormat('HH.mm').format(_date)}, ubah jam',
                                  style: AppText.body.copyWith(fontWeight: FontWeight.w500, color: c.primary),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // What the receipt held, read before judging the category below.
            if (_items.isNotEmpty) ...[
              const SizedBox(height: 18),
              FormLabel('Rincian item · ${_items.length} item'),
              _itemsCard(c),
            ],
            if (!transfer && chips.isNotEmpty) ...[
              const SizedBox(height: 18),
              const FormLabel('Kategori lain'),
              Wrap(
                spacing: AppSpace.tight,
                runSpacing: AppSpace.tight,
                children: [
                  for (final x in chips)
                    ChoiceChip(
                      label: Text(x['name'] as String),
                      selected: x['id'] == _categoryId,
                      showCheckmark: false,
                      labelStyle: AppText.label.copyWith(
                        fontSize: 14,
                        color: x['id'] == _categoryId ? c.onPrimary : c.ink,
                      ),
                      onSelected: (_) => _pickCategory(x['id'] as String),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 18),
            const FormLabel('Label'),
            LabelChips(labels: widget.labels, selected: _labelIds, onChanged: (ids) => _labelIds = ids),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(AppSpace.page, 12, AppSpace.page, 12 + MediaQuery.viewInsetsOf(context).bottom),
          child: Row(
            children: [
              if (_editing) ...[
                OutlinedButton.icon(
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Hapus'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.alert,
                    minimumSize: const Size(64, 56),
                    side: BorderSide(color: c.outline),
                  ),
                ),
                const SizedBox(width: AppSpace.gap),
              ],
              Expanded(
                child: FilledButton(
                  onPressed: _save,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  child: Text(_editing ? 'Simpan perubahan' : 'Simpan'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final _log = Logger('receipt');

/// Gemini's reading of a receipt photo (supabase/functions/parse-receipt): `amount` in whole
/// rupiah (0 when unreadable), `note`, `account_id`, `category_id` ("none" when unsure), `days_ago`,
/// `time` ("HH:mm", empty when not printed).
/// Null when Gemini can't be reached in time (offline, over quota).
Future<Map<String, dynamic>?> _readReceipt(
  List<int> jpeg,
  List<Map<String, dynamic>> accounts,
  List<Map<String, dynamic>> categories,
) async {
  try {
    final response = await supabase.functions
        .invoke(
          'parse-receipt',
          body: {
            'image': base64Encode(jpeg),
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
        .timeout(const Duration(seconds: 25)); // an image takes Gemini longer than a line of text
    if (response.data case final Map<String, dynamic> data) return data;
    _log.warning('parse-receipt answered ${response.data.runtimeType}');
  } on FunctionException catch (e) {
    _log.warning('parse-receipt failed with ${e.status}', e);
  } on Exception catch (e) {
    _log.warning('parse-receipt unreachable', e);
  }
  return null;
}

/// Edits one receipt line. Pops the changed [ReceiptItem], `false` to drop the line, or null.
class _ItemSheet extends StatefulWidget {
  const _ItemSheet({required this.item});

  final ReceiptItem item;

  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  late final _name = TextEditingController(text: widget.item.name);
  late final _amount = TextEditingController(
    text: NumberFormat.decimalPattern('id_ID').format(widget.item.amount / 100),
  );
  final _nameFocus = FocusNode();
  final _amountFocus = FocusNode();

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _nameFocus.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final amount = parseAmount(_amount.text);
    if (name.isEmpty) return showMessage(context, 'Nama item belum diisi.');
    if (amount == null) return showMessage(context, 'Harga tidak valid. Contoh: 25.000');
    haptic(Haptic.click);
    Navigator.pop(context, widget.item.copyWith(name: name, amount: amount));
  }

  @override
  Widget build(BuildContext context) => FormSheet(
    title: 'Ubah item',
    action: Row(
      children: [
        OutlinedButton(
          onPressed: () {
            haptic(Haptic.click);
            Navigator.pop(context, false);
          },
          style: OutlinedButton.styleFrom(minimumSize: const Size(64, 56)),
          child: const Text('Hapus'),
        ),
        const SizedBox(width: AppSpace.gap),
        Expanded(
          child: FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: const Text('Simpan'),
          ),
        ),
      ],
    ),
    children: [
      FormCard(
        children: [
          FormRow(
            icon: Icons.edit_outlined,
            label: 'Nama item',
            focusNode: _nameFocus,
            child: TextField(
              controller: _name,
              focusNode: _nameFocus,
              style: AppText.body.copyWith(fontWeight: FontWeight.w500),
              decoration: bareField('contoh: Teh Tarik'),
            ),
          ),
          FormRow(
            icon: Icons.payments_outlined,
            label: widget.item.qty > 1 ? 'Harga (${widget.item.qty} ×)' : 'Harga',
            focusNode: _amountFocus,
            child: MoneyField(controller: _amount, focusNode: _amountFocus),
          ),
        ],
      ),
    ],
  );
}

// ---------------------------------------------------------------- quick input

/// Saves one line of quick input ("bakso 25rb pakai dana", "makan 25rb parkir 5rb"), which may
/// hold several transactions. [onParsed] runs once the line is understood. With [review], and for
/// an entry with no category, a transfer, or an amount Gemini may have misread, the record form
/// opens instead of saving. [offline] skips Gemini: the local rules alone, at once.
Future<void> submitQuickInput(
  BuildContext context,
  String text, {
  VoidCallback? onParsed,
  bool review = false,
  bool offline = false,
}) async {
  final input = text.trim();
  if (input.isEmpty) return;
  final accounts = await db.getAll('SELECT id, name, provider, currency FROM accounts WHERE archived = 0');
  final categories = await db.getAll('SELECT id, name, type, keywords FROM categories WHERE archived = 0');
  if (!context.mounted) return;
  if (accounts.isEmpty) return askForAccount(context);
  final entries =
      (offline ? null : await _askGemini(input, accounts, categories)) ??
      [?parseQuickInput(input, accounts: accounts, categories: categories)];
  if (!context.mounted) return;
  if (entries.isEmpty) return showMessage(context, 'Nominal tidak ditemukan. Contoh: bakso 25rb pakai gopay');
  onParsed?.call();
  await saveQuickEntries(context, entries, accounts, categories, review: review);
}

/// Saves transactions read from one line. An entry that needs a check opens the record form.
Future<void> saveQuickEntries(
  BuildContext context,
  List<QuickEntry> entries,
  List<Map<String, dynamic>> accounts,
  List<Map<String, dynamic>> categories, {
  bool review = false,
}) async {
  final defaultAccountId = await _lastAccountId(accounts);
  final labelIds = await resolveLabelIds(entries.first.labels); // "#liburan" creates the label if needed

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
