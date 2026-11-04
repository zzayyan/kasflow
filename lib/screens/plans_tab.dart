import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../money.dart';
import '../reports.dart';
import '../ui.dart';
import 'labels_page.dart';
import 'record_form.dart';

// The Rencana tab: saving goals (A6) and budgets (A5).

const periodLabels = {'week': 'Mingguan', 'month': 'Bulanan', 'year': 'Tahunan'};

class _BudgetView {
  const _BudgetView(this.row, this.spent, this.end);

  final Map<String, dynamic> row;
  final int spent;
  final DateTime end;
}

class BudgetsTab extends StatelessWidget {
  const BudgetsTab({super.key});

  // Spending counts confirmed expenses in the budget's current period, on accounts that count
  // towards statistics, limited to the budget's categories, accounts and labels (empty list = all;
  // a record matches a label filter when it carries any of those labels).
  static const _spentSql = '''
    SELECT COALESCE(SUM(r.amount), 0) AS spent
    FROM records r JOIN accounts a ON a.id = r.account_id
    WHERE r.type = 'expense' AND r.status = 'confirmed' AND a.exclude_from_stats = 0
      AND julianday(r.occurred_at) >= julianday(?1) AND julianday(r.occurred_at) < julianday(?2)
      AND (json_array_length(?3) = 0 OR r.category_id IN (SELECT value FROM json_each(?3)))
      AND (json_array_length(?4) = 0 OR r.account_id IN (SELECT value FROM json_each(?4)))
      AND (json_array_length(?5) = 0 OR EXISTS (
        SELECT 1 FROM json_each(r.label_ids) l WHERE l.value IN (SELECT value FROM json_each(?5))))''';

  Stream<List<_BudgetView>> _watch() => db
      .watch('SELECT * FROM budgets ORDER BY name', triggerOnTables: const ['budgets', 'records', 'accounts'])
      .asyncMap((rows) async {
        final now = DateTime.now();
        return [
          for (final b in rows)
            await () async {
              final (start, end) = periodRange(b['period'] as String, now);
              final spent = await db.get(_spentSql, [
                utcIso(start),
                utcIso(end),
                b['category_ids'] ?? '[]',
                b['account_ids'] ?? '[]',
                b['label_ids'] ?? '[]',
              ]);
              return _BudgetView(b, spent['spent'] as int, end);
            }(),
        ];
      });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: _watch(),
      builder: (context, snap) {
        final budgets = snap.data;
        if (budgets == null) return const SizedBox.shrink();
        if (budgets.isEmpty) return const _Hint('Belum ada budget. Contoh: Makan bulanan 1,5jt.');
        return Column(children: [for (final b in budgets) _BudgetCard(b)]);
      },
    );
  }
}

/// Meter: the fill carries the state, the track is a lighter step of the same color.
class _Meter extends StatelessWidget {
  const _Meter({required this.value, required this.fill, required this.label});

  final double value;
  final Color fill;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Container(
          height: 8,
          color: fill.withValues(alpha: 0.22),
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            heightFactor: 1, // a childless ColoredBox would otherwise collapse to 0px tall
            widthFactor: value.clamp(0.0, 1.0),
            child: ColoredBox(color: fill),
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
    child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
  );
}

// ---------------------------------------------------------------- plans tab: goals (A6) + budgets (A5)

class PlansTab extends StatelessWidget {
  const PlansTab({super.key});

  @override
  Widget build(BuildContext context) {
    Widget header(String title, String add, VoidCallback onAdd) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 4),
      child: Row(
        children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
          TextButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: Text(add)),
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
      children: [
        header('Goal tabungan', 'Goal', () => showGoalForm(context)),
        const _GoalsList(),
        header('Budget', 'Budget', () => showBudgetForm(context)),
        const BudgetsTab(),
      ],
    );
  }
}

Future<void> showPlanChooser(BuildContext context) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('Goal tabungan baru'),
            subtitle: const Text('Target nominal, misalnya dana darurat atau HP baru'),
            onTap: () => Navigator.pop(context, 'goal'),
          ),
          ListTile(
            leading: const Icon(Icons.savings_outlined),
            title: const Text('Budget baru'),
            subtitle: const Text('Batas pengeluaran per minggu, bulan, atau tahun'),
            onTap: () => Navigator.pop(context, 'budget'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (choice == 'goal') return showGoalForm(context);
  if (choice == 'budget') return showBudgetForm(context);
}

class _GoalsList extends StatelessWidget {
  const _GoalsList();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      // Saved = the linked account's balance, derived from records like every balance.
      stream: db.watch('''
        SELECT g.*, a.name AS account_name, COALESCE(b.balance, 0) AS saved
        FROM goals g
        LEFT JOIN accounts a ON a.id = g.account_id
        LEFT JOIN ($accountBalancesSql) b ON b.id = g.account_id
        ORDER BY g.state = 'paused', g.target_date IS NULL, g.target_date, g.name'''),
      builder: (context, snap) {
        final goals = snap.data;
        if (goals == null) return const SizedBox.shrink();
        if (goals.isEmpty) return const _Hint('Belum ada goal. Contoh: Dana darurat 10jt, liburan, HP baru.');
        return Column(children: [for (final g in goals) _GoalCard(g)]);
      },
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard(this.g);

  final Map<String, dynamic> g;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final saved = g['saved'] as int;
    final target = g['target_amount'] as int;
    final targetDate = g['target_date'] == null ? null : DateTime.parse(g['target_date'] as String);
    final plan = planGoal(saved: saved, target: target, targetDate: targetDate, now: DateTime.now());
    final paused = g['state'] == 'paused';
    final accent = VizColors.of(context).bar;
    final (fill, icon, iconColor, status) = plan.reached
        ? (VizColors.success, Icons.check_circle_outline, VizColors.success, 'Tercapai')
        : paused
        ? (muted, Icons.pause_circle_outline, muted, 'Dijeda')
        : plan.late
        ? (accent, Icons.warning_amber_rounded, VizColors.warning, 'Lewat tanggal target')
        : (
            accent,
            Icons.flag_outlined,
            accent,
            plan.perMonth != null
                ? 'Nabung ${formatAmount(plan.perMonth!)}/bulan'
                : 'Sisa ${formatAmount(plan.remaining)}',
          );
    final details = [
      '${formatAmount(saved)} dari ${formatAmount(target)}',
      if (targetDate != null) 'target ${DateFormat('d MMM yyyy', 'id_ID').format(targetDate)}',
      // The account is worth naming only when it isn't the one created for this goal.
      if (g['account_name'] != g['name']) 'di ${g['account_name'] ?? 'akun terhapus'}',
    ].join(' · ');
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onLongPress: () => _options(context, paused),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(g['name'] as String, style: theme.textTheme.titleSmall)),
                        Text(
                          percentOf(saved.clamp(0, target), target),
                          style: theme.textTheme.labelMedium?.copyWith(color: muted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _Meter(value: plan.progress, fill: fill, label: '${percentOf(saved, target)} terkumpul, $status'),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(icon, size: 16, color: iconColor),
                        const SizedBox(width: 4),
                        Expanded(child: Text(status, style: theme.textTheme.labelMedium)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(details, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                  ],
                ),
              ),
              if (!plan.reached && !paused && g['account_id'] != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Tambah tabungan'),
                    // A transfer into the goal's account keeps every balance right.
                    onPressed: () => showRecordForm(
                      context,
                      prefill: Prefill(
                        type: 'transfer',
                        transferAccountId: g['account_id'] as String,
                        note: 'Tabungan ${g['name']}',
                      ),
                    ),
                  ),
                )
              else
                const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _options(BuildContext context, bool paused) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(paused ? Icons.play_circle_outline : Icons.pause_circle_outline),
              title: Text(paused ? 'Lanjutkan goal' : 'Jeda goal'),
              onTap: () => Navigator.pop(context, 'toggle'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Hapus goal'),
              subtitle: const Text('Akun tabungan dan saldonya tetap ada'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'toggle') {
      await db.execute('UPDATE goals SET state = ?, updated_at = ? WHERE id = ?', [
        paused ? 'active' : 'paused',
        nowIso(),
        g['id'],
      ]);
    } else if (choice == 'delete') {
      await db.execute('DELETE FROM goals WHERE id = ?', [g['id']]);
    }
  }
}

const _newAccount = '__new';

Future<void> showGoalForm(BuildContext context) async {
  final accounts = await db.getAll("SELECT id, name FROM accounts WHERE archived = 0 ORDER BY type != 'savings', name");
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => GoalForm(accounts: accounts),
  );
}

class GoalForm extends StatefulWidget {
  const GoalForm({super.key, required this.accounts});

  final List<Map<String, dynamic>> accounts;

  @override
  State<GoalForm> createState() => _GoalFormState();
}

class _GoalFormState extends State<GoalForm> {
  final _name = TextEditingController();
  final _target = TextEditingController();
  final _saved = TextEditingController();
  DateTime? _date;
  String _accountId = _newAccount;

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return showMessage(context, 'Isi nama goal, contoh: Dana darurat');
    final target = parseAmount(_target.text);
    if (target == null) return showMessage(context, 'Target tidak valid. Contoh: 10jt');
    final savedText = _saved.text.trim();
    final saved = _accountId != _newAccount || savedText.isEmpty ? 0 : parseAmount(savedText);
    if (saved == null) return showMessage(context, 'Jumlah yang sudah terkumpul tidak valid.');
    final now = nowIso();
    await db.writeTransaction((tx) async {
      var accountId = _accountId;
      if (accountId == _newAccount) {
        // A dedicated savings account: its balance is the goal's progress.
        accountId = (await tx.get('SELECT uuid() AS id'))['id'] as String;
        await tx.execute(
          '''
          INSERT INTO accounts (id, user_id, name, type, currency, initial_balance, archived, exclude_from_stats,
            created_at, updated_at)
          VALUES (?, ?, ?, 'savings', 'IDR', ?, 0, 0, ?, ?)''',
          [accountId, currentUserId, name, saved, now, now],
        );
      }
      await tx.execute(
        '''
        INSERT INTO goals (id, user_id, name, target_amount, currency, account_id, target_date, state,
          created_at, updated_at)
        VALUES (uuid(), ?, ?, ?, 'IDR', ?, ?, 'active', ?, ?)''',
        [currentUserId, name, target, accountId, _date == null ? null : dateOnly(_date!), now, now],
      );
    });
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final date = _date;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Nama goal', hintText: 'contoh: Dana darurat'),
            ),
            TextField(
              controller: _target,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Target', prefixText: 'Rp '),
            ),
            DropdownButtonFormField(
              initialValue: _accountId,
              decoration: const InputDecoration(labelText: 'Simpan di akun'),
              items: [
                const DropdownMenuItem(value: _newAccount, child: Text('Akun tabungan baru')),
                for (final a in widget.accounts)
                  DropdownMenuItem(value: a['id'] as String, child: Text(a['name'] as String)),
              ],
              onChanged: (v) => setState(() => _accountId = v!),
            ),
            if (_accountId == _newAccount)
              TextField(
                controller: _saved,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Sudah terkumpul (opsional)', prefixText: 'Rp '),
              )
            else
              const Padding(padding: EdgeInsets.only(top: 8), child: Text('Progres goal mengikuti saldo akun ini.')),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event),
              title: const Text('Tanggal target (opsional)'),
              subtitle: Text(date == null ? 'Tanpa tanggal' : DateFormat('d MMMM yyyy', 'id_ID').format(date)),
              trailing: date == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Hapus tanggal',
                      onPressed: () => setState(() => _date = null),
                    ),
              onTap: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: date ?? DateTime(now.year + 1, now.month, now.day),
                  firstDate: now,
                  lastDate: DateTime(now.year + 30),
                );
                if (picked != null) setState(() => _date = picked);
              },
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: const Text('Simpan')),
          ],
        ),
      ),
    );
  }
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard(this.b);

  final _BudgetView b;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final limit = b.row['amount'] as int;
    final level = budgetLevel(b.spent, limit);
    // Meter: the fill carries severity, the track is a lighter step of the same color.
    final (fill, icon, status) = switch (level) {
      BudgetLevel.ok => (VizColors.of(context).bar, Icons.check_circle_outline, 'Aman'),
      BudgetLevel.warning => (VizColors.warning, Icons.warning_amber_rounded, 'Hampir habis'),
      BudgetLevel.over => (VizColors.critical, Icons.error_outline, 'Lewat batas'),
    };
    final daily = dailyAllowance(b.spent, limit, b.end, DateTime.now());
    final remaining = level == BudgetLevel.over
        ? 'Lebih ${formatAmount(b.spent - limit)}'
        : 'Sisa ${formatAmount(limit - b.spent)}${daily != null ? ' · ${formatAmount(daily)}/hari' : ''}';
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onLongPress: () => _confirmDelete(context),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(b.row['name'] as String, style: theme.textTheme.titleSmall)),
                  Text(periodLabels[b.row['period']] ?? '', style: theme.textTheme.labelSmall?.copyWith(color: muted)),
                ],
              ),
              const SizedBox(height: 10),
              _Meter(
                value: limit == 0 ? 0 : b.spent / limit,
                fill: fill,
                label: '${percentOf(b.spent, limit)} terpakai, $status',
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(icon, size: 16, color: fill),
                  const SizedBox(width: 4),
                  Text(status, style: theme.textTheme.labelMedium),
                  const Spacer(),
                  Text('${formatAmount(b.spent)} dari ${formatAmount(limit)}', style: theme.textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 2),
              Text(remaining, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hapus budget "${b.row['name']}"?'),
        content: const Text('Transaksinya tidak ikut terhapus.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (ok == true) await db.execute('DELETE FROM budgets WHERE id = ?', [b.row['id']]);
  }
}

Future<void> showBudgetForm(BuildContext context) async {
  final categories = await db.getAll(
    "SELECT id, name FROM categories WHERE type = 'expense' AND archived = 0 ORDER BY name",
  );
  final labels = await db.getAll('SELECT id, name FROM labels ORDER BY name COLLATE NOCASE');
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => BudgetForm(categories: categories, labels: labels),
  );
}

class BudgetForm extends StatefulWidget {
  const BudgetForm({super.key, required this.categories, required this.labels});

  final List<Map<String, dynamic>> categories;
  final List<Map<String, dynamic>> labels;

  @override
  State<BudgetForm> createState() => _BudgetFormState();
}

class _BudgetFormState extends State<BudgetForm> {
  final _name = TextEditingController();
  final _amount = TextEditingController();
  String _period = 'month';
  final _selected = <String>{};
  var _labelIds = <String>{};

  Future<void> _save() async {
    final amount = parseAmount(_amount.text);
    if (amount == null) return showMessage(context, 'Batas tidak valid. Contoh: 1,5jt atau 500rb');
    final names = [
      for (final c in widget.categories)
        if (_selected.contains(c['id'])) c['name'] as String,
    ];
    final name = _name.text.trim().isNotEmpty
        ? _name.text.trim()
        : names.isEmpty
        ? 'Semua pengeluaran'
        : names.join(', ');
    final (start, _) = periodRange(_period, DateTime.now());
    final now = nowIso();
    await db.execute(
      '''
      INSERT INTO budgets (id, user_id, name, period, amount, currency, start_date,
        category_ids, account_ids, label_ids, created_at, updated_at)
      VALUES (uuid(), ?, ?, ?, ?, 'IDR', ?, ?, '[]', ?, ?, ?)''',
      [
        currentUserId,
        name,
        _period,
        amount,
        DateFormat('yyyy-MM-dd').format(start),
        jsonEncode([..._selected]),
        jsonEncode([..._labelIds]),
        now,
        now,
      ],
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton(
            segments: [for (final e in periodLabels.entries) ButtonSegment(value: e.key, label: Text(e.value))],
            selected: {_period},
            onSelectionChanged: (s) => setState(() => _period = s.first),
          ),
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Batas pengeluaran', prefixText: 'Rp '),
          ),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Nama (opsional)', hintText: 'contoh: Makan bulanan'),
          ),
          const SizedBox(height: 12),
          Text('Kategori (kosongkan untuk semua pengeluaran)', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final c in widget.categories)
                    FilterChip(
                      label: Text(c['name'] as String),
                      selected: _selected.contains(c['id']),
                      onSelected: (on) =>
                          setState(() => on ? _selected.add(c['id'] as String) : _selected.remove(c['id'])),
                    ),
                ],
              ),
            ),
          ),
          if (widget.labels.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Label (opsional: hanya transaksi berlabel ini)', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            LabelChips(labels: widget.labels, selected: _labelIds, onChanged: (ids) => _labelIds = ids),
          ],
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Simpan')),
        ],
      ),
    );
  }
}
