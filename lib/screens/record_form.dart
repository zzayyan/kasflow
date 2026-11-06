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
import '../theme.dart';
import '../ui.dart';
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
}

Future<void> showRecordForm(BuildContext context, {Prefill? prefill}) async {
  // Archived accounts and categories stay selectable when the record being edited uses them.
  final accounts = await db.getAll(
    '''
    SELECT a.id, a.name, a.currency, a.provider, b.balance
    FROM accounts a JOIN ($accountBalancesSql) b ON b.id = a.id
    WHERE a.archived = 0 OR a.id IN (?, ?) ORDER BY a.name''',
    [prefill?.accountId, prefill?.transferAccountId],
  );
  if (!context.mounted) return;
  if (accounts.isEmpty) {
    showMessage(context, 'Buat akun dulu lewat Beranda, tombol Akun.');
    return;
  }
  // Most used first, so the quick chips under the form hold the likely picks.
  final categories = await db.getAll(
    '''
    SELECT c.id, c.name, c.type, c.keywords, c.icon FROM categories c
    WHERE c.archived = 0 OR c.id = ?
    ORDER BY (SELECT COUNT(*) FROM records r WHERE r.category_id = c.id) DESC, c.name''',
    [prefill?.categoryId],
  );
  final labels = await db.getAll('SELECT id, name FROM labels ORDER BY name COLLATE NOCASE');
  if (!context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => RecordForm(accounts: accounts, categories: categories, labels: labels, prefill: prefill),
    ),
  );
}

class RecordForm extends StatefulWidget {
  const RecordForm({super.key, required this.accounts, required this.categories, required this.labels, this.prefill});

  final List<Map<String, dynamic>> accounts;
  final List<Map<String, dynamic>> categories;
  final List<Map<String, dynamic>> labels;
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

  @override
  void initState() {
    super.initState();
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
    if (_categoryPicked || _type == 'transfer') return;
    final guess = guessCategoryId(note, _type, widget.categories);
    if (guess != _categoryId) setState(() => _categoryId = guess);
  }

  // Only for a fresh record that nothing filled in yet (not an edit, a notification or a bill).
  late final bool _showQuick = !_editing && widget.prefill?.amount == null;

  /// The quick field fills the form as the user types: "bakso 25rb pakai gopay".
  void _onQuickChanged(String text) {
    final e = parseQuickInput(text, accounts: widget.accounts, categories: widget.categories);
    if (e == null) return;
    setState(() {
      _amount.text = NumberFormat.decimalPattern('id_ID').format(e.amount / 100);
      _type = e.type;
      _note.text = e.note;
      _date = e.date;
      if (e.accountId case final id?) _accountId = id;
      _categoryId = e.categoryId;
      _categoryPicked = false;
      _quickLabels = e.labels;
    });
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
      });
      FocusManager.instance.primaryFocus?.unfocus(); // show the filled form, not the keyboard
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  void _pickCategory(String? id) => setState(() {
    _categoryId = id;
    _categoryPicked = true;
  });

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
    setState(() => _date = DateTime(day.year, day.month, day.day, _date.hour, _date.minute));
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_date));
    if (t == null || !mounted) return;
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
    if (mounted) Navigator.pop(context);
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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 20),
        children: [
          if (_showQuick) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(
                'Ketik cepat, kolom di bawah terisi sendiri',
                style: AppText.caption.copyWith(color: c.inkMuted),
              ),
            ),
            TextField(
              controller: _quick,
              autofocus: true,
              onChanged: _onQuickChanged,
              style: AppText.body,
              decoration: InputDecoration(
                hintText: 'bakso 25rb pakai gopay',
                fillColor: c.primarySoft,
                prefixIcon: Icon(Icons.bolt, size: 20, color: c.primary),
                suffixIcon: _reading
                    ? Padding(
                        padding: const EdgeInsets.all(14),
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: c.primary),
                        ),
                      )
                    : IconButton(
                        tooltip: 'Foto struk',
                        onPressed: _scanReceipt,
                        icon: Icon(Icons.photo_camera_outlined, color: c.primary),
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
            const SizedBox(height: 18),
          ],
          PillSwitch(
            options: const [('expense', 'Keluar'), ('income', 'Masuk'), ('transfer', 'Transfer')],
            value: _type,
            onChanged: (type) => setState(() {
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
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            inputFormatters: const [AmountInputFormatter()],
                            style: AppText.amountXl.copyWith(color: c.ink),
                            decoration: bareField('0'),
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
                child: TextField(
                  controller: _note,
                  focusNode: _noteFocus,
                  onChanged: _onNoteChanged,
                  style: AppText.body.copyWith(fontWeight: FontWeight.w500),
                  decoration: bareField('contoh: bakso, bensin, token PLN'),
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
                trailing: formatAmount(account['balance'] as int),
                onTap: () async {
                  final id = await chooseOne(context, transfer ? 'Dari akun' : 'Akun', _accountOptions(), _accountId);
                  if (id != null) {
                    setState(() {
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
                  trailing: target == null ? null : formatAmount(target['balance'] as int),
                  onTap: () async {
                    final id = await chooseOne(context, 'Ke akun', _accountOptions(except: _accountId), _targetId);
                    if (id != null) setState(() => _targetId = id);
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
          if (!transfer && chips.isNotEmpty) ...[
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Text('Kategori lain', style: AppText.label.copyWith(color: c.inkMuted)),
            ),
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
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text('Label', style: AppText.label.copyWith(color: c.inkMuted)),
          ),
          LabelChips(labels: widget.labels, selected: _labelIds, onChanged: (ids) => _labelIds = ids),
        ],
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
