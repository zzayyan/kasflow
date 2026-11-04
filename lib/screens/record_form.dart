import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../categorize.dart';
import '../db.dart';
import '../money.dart';
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
  // Archived accounts and categories stay selectable when the record being edited uses them;
  // a dropdown whose current value is missing from its items would throw.
  final accounts = await db.getAll(
    'SELECT id, name, currency, provider FROM accounts WHERE archived = 0 OR id IN (?, ?) ORDER BY name',
    [prefill?.accountId, prefill?.transferAccountId],
  );
  if (!context.mounted) return;
  if (accounts.isEmpty) {
    showMessage(context, 'Buat akun dulu lewat Beranda, tombol Akun.');
    return;
  }
  final categories = await db.getAll(
    'SELECT id, name, type, keywords FROM categories WHERE archived = 0 OR id = ? ORDER BY name',
    [prefill?.categoryId],
  );
  final labels = await db.getAll('SELECT id, name FROM labels ORDER BY name COLLATE NOCASE');
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => RecordForm(accounts: accounts, categories: categories, labels: labels, prefill: prefill),
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
  final _amount = TextEditingController();
  final _note = TextEditingController();
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

  Future<void> _save() async {
    final amount = parseAmount(_amount.text);
    if (amount == null) return showMessage(context, 'Nominal tidak valid. Contoh: 25.000 atau 25rb');
    if (_type == 'transfer' && (_targetId == null || _targetId == _accountId)) {
      return showMessage(context, 'Pilih akun tujuan yang berbeda.');
    }
    final currency = widget.accounts.firstWhere((a) => a['id'] == _accountId)['currency'] as String;
    final p = widget.prefill;
    final note = _note.text.trim();
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
  Widget build(BuildContext context) {
    final categories = widget.categories.where((c) => c['type'] == _type).toList();
    DropdownMenuItem<String> accountItem(Map<String, dynamic> a) =>
        DropdownMenuItem(value: a['id'] as String, child: Text(a['name'] as String));
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton(
            segments: const [
              ButtonSegment(value: 'expense', label: Text('Keluar')),
              ButtonSegment(value: 'income', label: Text('Masuk')),
              ButtonSegment(value: 'transfer', label: Text('Transfer')),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() {
              _type = s.first;
              _categoryPicked = false;
              _categoryId = _type == 'transfer' ? null : guessCategoryId(_note.text, _type, widget.categories);
            }),
          ),
          TextField(
            controller: _amount,
            autofocus: !_editing,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Nominal', prefixText: 'Rp '),
          ),
          DropdownButtonFormField(
            initialValue: _accountId,
            decoration: InputDecoration(labelText: _type == 'transfer' ? 'Dari akun' : 'Akun'),
            items: widget.accounts.map(accountItem).toList(),
            onChanged: (v) => setState(() => _accountId = v!),
          ),
          if (_type == 'transfer')
            DropdownButtonFormField(
              initialValue: _targetId,
              decoration: const InputDecoration(labelText: 'Ke akun'),
              items: widget.accounts.where((a) => a['id'] != _accountId).map(accountItem).toList(),
              onChanged: (v) => setState(() => _targetId = v),
            )
          else
            DropdownButtonFormField(
              key: ValueKey('$_type/$_categoryId'), // rebuild when the type or the guessed category changes
              initialValue: _categoryId,
              decoration: const InputDecoration(labelText: 'Kategori'),
              items: [
                for (final c in categories)
                  DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String)),
              ],
              onChanged: (v) => setState(() {
                _categoryId = v;
                _categoryPicked = true;
              }),
            ),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
              labelText: 'Catatan (opsional)',
              hintText: 'contoh: bakso, bensin, token PLN',
            ),
            onChanged: _onNoteChanged,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: Text(DateFormat('EEEE, d MMMM yyyy', 'id_ID').format(_date)),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(2000),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              // Keep the time of day: a new record has "now", an edited one keeps its original time.
              if (picked != null) {
                setState(() => _date = DateTime(picked.year, picked.month, picked.day, _date.hour, _date.minute));
              }
            },
          ),
          LabelChips(labels: widget.labels, selected: _labelIds, onChanged: (ids) => _labelIds = ids),
          const SizedBox(height: 12),
          if (_editing)
            Row(
              children: [
                TextButton.icon(
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Hapus'),
                  style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(onPressed: _save, child: const Text('Simpan perubahan')),
                ),
              ],
            )
          else
            FilledButton(onPressed: _save, child: const Text('Simpan')),
        ],
      ),
    );
  }
}
