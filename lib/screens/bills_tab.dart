import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../categorize.dart';
import '../db.dart';
import '../money.dart';
import '../recurrence.dart';
import '../ui.dart';
import 'record_form.dart';

// A7: planned payments (tagihan rutin) with reminders.

const _channel = MethodChannel('cashflow/notifications');

const frequencyLabels = {'WEEKLY': 'Mingguan', 'MONTHLY': 'Bulanan', 'YEARLY': 'Tahunan'};
const reminderLabels = {0: 'Di hari H', 1: '1 hari sebelum', 3: '3 hari sebelum', 7: '7 hari sebelum'};

DateTime _date(Object? yyyyMmDd) => DateTime.parse(yyyyMmDd as String);

/// Keeps Android alarms in step with the planned_payments table: one reminder per bill, for its
/// next due date. Runs while the app is open; data synced from another device while the app is
/// closed is picked up on the next start.
StreamSubscription<void> keepRemindersScheduled() => db
    .watch('SELECT id, name, type, amount, next_due_date, remind_days_before FROM planned_payments')
    .listen((rows) => scheduleReminders(rows.toList()));

Future<void> scheduleReminders(List<Map<String, dynamic>> bills) {
  final now = DateTime.now();
  final date = DateFormat('d MMM', 'id_ID');
  final reminders = [
    for (final (i, b) in bills.indexed)
      if (reminderAt(_date(b['next_due_date']), b['remind_days_before'] as int) case final at when at.isAfter(now))
        {
          'id': i + 1,
          'at': at.millisecondsSinceEpoch,
          'title': '${b['type'] == 'income' ? 'Pemasukan' : 'Tagihan'}: ${b['name']}',
          'text':
              '${formatAmount(b['amount'] as int)} · jatuh tempo '
              '${dueLabel(b['remind_days_before'] as int).toLowerCase()} (${date.format(_date(b['next_due_date']))})',
        },
  ];
  return _channel.invokeMethod('scheduleReminders', reminders);
}

/// Bills that are due within their reminder window or late, for the navigation badge.
Stream<int> watchDueBillCount() => db
    .watch('SELECT next_due_date, remind_days_before FROM planned_payments')
    .map(
      (rows) => rows
          .where(
            (b) =>
                dueStatus(_date(b['next_due_date']), b['remind_days_before'] as int, DateTime.now()).$2 !=
                DueLevel.upcoming,
          )
          .length,
    );

class BillsTab extends StatelessWidget {
  const BillsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: db.watch('''
        SELECT p.*, a.name AS account_name FROM planned_payments p
        LEFT JOIN accounts a ON a.id = p.account_id
        ORDER BY p.next_due_date, p.name'''),
      builder: (context, snap) {
        final rows = snap.data;
        if (rows == null) return const Center(child: CircularProgressIndicator());
        if (rows.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Belum ada tagihan rutin. Tekan + untuk menambah, misalnya listrik, kos, cicilan, atau gaji.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: rows.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _BillTile(rows[i]),
        );
      },
    );
  }
}

class _BillTile extends StatelessWidget {
  const _BillTile(this.b);

  final Map<String, dynamic> b;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final due = _date(b['next_due_date']);
    final (days, level) = dueStatus(due, b['remind_days_before'] as int, DateTime.now());
    // Status always pairs an icon and a label with its color.
    final (icon, color) = switch (level) {
      DueLevel.overdue => (Icons.error_outline, VizColors.critical),
      DueLevel.soon => (Icons.schedule, VizColors.warning),
      DueLevel.upcoming => (Icons.event, theme.colorScheme.onSurfaceVariant),
    };
    final income = b['type'] == 'income';
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(b['name'] as String),
      subtitle: Text(
        '${dueLabel(days)} · ${DateFormat('d MMM yyyy', 'id_ID').format(due)}\n'
        '${formatAmount(b['amount'] as int)} · ${b['account_name'] ?? '?'} · '
        '${frequencyLabels[frequencyOf(b['rrule'] as String)]}',
      ),
      isThreeLine: true,
      trailing: FilledButton.tonal(onPressed: () => _pay(context), child: Text(income ? 'Terima' : 'Bayar')),
      onLongPress: () => _options(context),
    );
  }

  /// Opens the record form prefilled; saving records it and moves the bill to its next due date.
  void _pay(BuildContext context) => showRecordForm(
    context,
    prefill: Prefill(
      amount: b['amount'] as int, // editable: bills like electricity vary month to month
      type: b['type'] as String,
      accountId: b['account_id'] as String,
      categoryId: b['category_id'] as String?,
      note: b['name'] as String,
      source: 'planned',
      plannedPaymentId: b['id'] as String,
      nextDue: nextDueDate(b['rrule'] as String, _date(b['next_due_date'])),
    ),
  );

  Future<void> _options(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.skip_next),
              title: const Text('Lewati periode ini'),
              subtitle: const Text('Tidak dicatat, jatuh tempo pindah ke periode berikutnya'),
              onTap: () => Navigator.pop(context, 'skip'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Hapus tagihan'),
              subtitle: const Text('Transaksi yang sudah tercatat tidak ikut terhapus'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    final id = b['id'];
    if (choice == 'skip') {
      final next = nextDueDate(b['rrule'] as String, _date(b['next_due_date']));
      await db.execute('UPDATE planned_payments SET next_due_date = ?, updated_at = ? WHERE id = ?', [
        dateOnly(next),
        nowIso(),
        id,
      ]);
    } else if (choice == 'delete') {
      await db.execute('DELETE FROM planned_payments WHERE id = ?', [id]);
    }
  }
}

Future<void> showBillForm(BuildContext context) async {
  final accounts = await db.getAll('SELECT id, name, currency FROM accounts WHERE archived = 0 ORDER BY name');
  final categories = await db.getAll(
    'SELECT id, name, type, keywords FROM categories WHERE archived = 0 ORDER BY name',
  );
  if (!context.mounted) return;
  if (accounts.isEmpty) return showMessage(context, 'Buat akun dulu lewat Beranda, tombol Akun saya.');
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => BillForm(accounts: accounts, categories: categories),
  );
}

class BillForm extends StatefulWidget {
  const BillForm({super.key, required this.accounts, required this.categories});

  final List<Map<String, dynamic>> accounts;
  final List<Map<String, dynamic>> categories;

  @override
  State<BillForm> createState() => _BillFormState();
}

class _BillFormState extends State<BillForm> {
  final _name = TextEditingController();
  final _amount = TextEditingController();
  String _type = 'expense';
  late String _accountId = widget.accounts.first['id'] as String;
  String? _categoryId;
  bool _categoryPicked = false;
  String _frequency = 'MONTHLY';
  DateTime _firstDue = DateTime.now();
  int _remind = 1;

  void _onNameChanged(String name) {
    if (_categoryPicked) return;
    final guess = guessCategoryId(name, _type, widget.categories);
    if (guess != _categoryId) setState(() => _categoryId = guess);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return showMessage(context, 'Isi nama tagihan, contoh: Listrik PLN');
    final amount = parseAmount(_amount.text);
    if (amount == null) return showMessage(context, 'Nominal tidak valid. Contoh: 350rb');
    final currency = widget.accounts.firstWhere((a) => a['id'] == _accountId)['currency'];
    final now = nowIso();
    await db.execute(
      '''
      INSERT INTO planned_payments (id, user_id, name, account_id, category_id, type, amount, currency,
        rrule, next_due_date, remind_days_before, created_at, updated_at)
      VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        currentUserId,
        name,
        _accountId,
        _categoryId,
        _type,
        amount,
        currency,
        buildRule(_frequency, _firstDue),
        dateOnly(_firstDue),
        _remind,
        now,
        now,
      ],
    );
    // Android 13+ asks once; reminders are only shown after the user allows notifications.
    await _channel.invokeMethod('requestPostNotifications');
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final categories = widget.categories.where((c) => c['type'] == _type).toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton(
              segments: const [
                ButtonSegment(value: 'expense', label: Text('Tagihan')),
                ButtonSegment(value: 'income', label: Text('Pemasukan')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() {
                _type = s.first;
                _categoryPicked = false;
                _categoryId = guessCategoryId(_name.text, _type, widget.categories);
              }),
            ),
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Nama', hintText: 'contoh: Listrik PLN, Kos, Gaji'),
              onChanged: _onNameChanged,
            ),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Nominal', prefixText: 'Rp '),
            ),
            DropdownButtonFormField(
              initialValue: _accountId,
              decoration: const InputDecoration(labelText: 'Akun'),
              items: [
                for (final a in widget.accounts)
                  DropdownMenuItem(value: a['id'] as String, child: Text(a['name'] as String)),
              ],
              onChanged: (v) => setState(() => _accountId = v!),
            ),
            DropdownButtonFormField(
              key: ValueKey('$_type/$_categoryId'),
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
            const SizedBox(height: 12),
            SegmentedButton(
              segments: [for (final e in frequencyLabels.entries) ButtonSegment(value: e.key, label: Text(e.value))],
              selected: {_frequency},
              onSelectionChanged: (s) => setState(() => _frequency = s.first),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event),
              title: const Text('Jatuh tempo berikutnya'),
              subtitle: Text(DateFormat('EEEE, d MMMM yyyy', 'id_ID').format(_firstDue)),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _firstDue,
                  firstDate: DateTime.now().subtract(const Duration(days: 365)),
                  lastDate: DateTime.now().add(const Duration(days: 366 * 2)),
                );
                if (picked != null) setState(() => _firstDue = picked);
              },
            ),
            DropdownButtonFormField(
              initialValue: _remind,
              decoration: const InputDecoration(labelText: 'Ingatkan (pukul 09.00)'),
              items: [for (final e in reminderLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => setState(() => _remind = v!),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: const Text('Simpan')),
          ],
        ),
      ),
    );
  }
}
