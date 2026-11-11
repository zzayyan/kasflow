import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../money.dart';
import '../recurrence.dart';
import '../reports.dart';
import '../theme.dart';
import '../ui.dart';
import 'bills_tab.dart';
import 'labels_page.dart';
import 'record_form.dart';

// The Rencana tab: planned payments (A7), budgets (A5) and saving goals (A6), after the
// "E · Rencana" and "Kosong · Rencana" artboards of the Cashflow UI/UX canvas.

const periodLabels = {'week': 'Mingguan', 'month': 'Bulanan', 'year': 'Tahunan'};
const _periodNouns = {'week': 'minggu', 'month': 'bulan', 'year': 'tahun'};

class BudgetView {
  const BudgetView(this.row, this.spent, [this.spentToday = 0]);

  final Map<String, dynamic> row;
  final int spent; // this period, today included
  final int spentToday;
}

/// The budget Beranda's "Jatah hari ini" follows: the one the user picked ([pickedId], this phone's
/// 'home_budget' pref) while it exists; otherwise a monthly one before a weekly one before the rest,
/// and among those the largest, i.e. the everyday living budget rather than a small side budget.
BudgetView? mainBudget(List<BudgetView> budgets, {String? pickedId}) {
  if (budgets.where((b) => b.row['id'] == pickedId).firstOrNull case final picked?) return picked;
  int rank(BudgetView b) => const {'month': 0, 'week': 1}[b.row['period']] ?? 2;
  final sorted = [...budgets]
    ..sort((a, b) {
      final byPeriod = rank(a).compareTo(rank(b));
      return byPeriod != 0 ? byPeriod : (b.row['amount'] as int).compareTo(a.row['amount'] as int);
    });
  return sorted.firstOrNull;
}

// Spending counts confirmed expenses in the budget's current period, on accounts that count
// towards statistics, limited to the budget's categories, accounts and labels (empty list = all;
// a record matches a label filter when it carries any of those labels).
const budgetSpentSql = 'SELECT COALESCE(SUM(r.amount), 0) AS spent $_budgetRecordsSql';

// The records a budget counts; ?1..?5 are period start, end, category, account and label ids.
const _budgetRecordsSql = '''
  FROM records r JOIN accounts a ON a.id = r.account_id
  WHERE r.type = 'expense' AND r.status = 'confirmed' AND a.exclude_from_stats = 0
    AND COALESCE(r.exclude_from_budget, 0) = 0
    AND julianday(r.occurred_at) >= julianday(?1) AND julianday(r.occurred_at) < julianday(?2)
    AND (json_array_length(?3) = 0 OR r.category_id IN (SELECT value FROM json_each(?3)))
    AND (json_array_length(?4) = 0 OR r.account_id IN (SELECT value FROM json_each(?4)))
    AND (json_array_length(?5) = 0 OR EXISTS (
      SELECT 1 FROM json_each(r.label_ids) l WHERE l.value IN (SELECT value FROM json_each(?5))))''';

/// Budgets with what each spent in its current period, kept fresh as records change.
Stream<List<BudgetView>> watchBudgets() => db
    .watch('SELECT * FROM budgets ORDER BY name', triggerOnTables: const ['budgets', 'records', 'accounts', 'prefs'])
    .asyncMap((rows) async {
      final now = DateTime.now();
      return [
        for (final b in rows)
          await () async {
            final (start, end) = periodRange(b['period'] as String, now);
            final today = DateTime(now.year, now.month, now.day);
            Future<int> spentBetween(DateTime from, DateTime to) async => (await db.get(budgetSpentSql, [
              utcIso(from),
              utcIso(to),
              b['category_ids'] ?? '[]',
              b['account_ids'] ?? '[]',
              b['label_ids'] ?? '[]',
            ]))['spent'] as int;
            return BudgetView(
              b,
              await spentBetween(start, end),
              await spentBetween(today, DateTime(today.year, today.month, today.day + 1)),
            );
          }(),
      ];
    });

class PlansTab extends StatefulWidget {
  const PlansTab({super.key});

  @override
  State<PlansTab> createState() => _PlansTabState();
}

class _PlansTabState extends State<PlansTab> {
  // One subscription per query, results in fields (db.watch streams can be listened to once only).
  final _subs = <StreamSubscription<void>>[];
  List<Map<String, dynamic>>? _bills;
  List<BudgetView>? _budgets;
  List<Map<String, dynamic>>? _goals;

  void _set(VoidCallback change) {
    if (mounted) setState(change);
  }

  @override
  void initState() {
    super.initState();
    _subs.addAll([
      db
          .watch('SELECT * FROM planned_payments ORDER BY next_due_date, name')
          .listen((rows) => _set(() => _bills = rows)),
      watchBudgets()
          .listen((rows) => _set(() => _budgets = rows)),
      // Saved = the linked account's balance, derived from records like every balance.
      db
          .watch('''
            SELECT g.*, a.name AS account_name, COALESCE(b.balance, 0) AS saved
            FROM goals g
            LEFT JOIN accounts a ON a.id = g.account_id
            LEFT JOIN ($accountBalancesSql) b ON b.id = g.account_id
            ORDER BY g.state = 'paused', g.target_date IS NULL, g.target_date, g.name''')
          .listen((rows) => _set(() => _goals = rows)),
    ]);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final bills = _bills, budgets = _budgets, goals = _goals;
    const gap = SizedBox(height: 22);
    return SafeArea(
      bottom: false,
      child: bills == null || budgets == null || goals == null
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.fromLTRB(AppSpace.page, 16, AppSpace.page, 24),
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Rencana', style: AppText.title)),
                    IconButton(
                      tooltip: 'Tambah tagihan, budget, atau goal',
                      onPressed: () => showPlanChooser(context),
                      style: IconButton.styleFrom(backgroundColor: c.surface, fixedSize: const Size.square(46)),
                      icon: Icon(Icons.add, color: c.ink),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (bills.isEmpty) const _NoBills() else _Bills(bills),
                gap,
                if (budgets.isEmpty) const NoBudgets() else BudgetList(budgets),
                gap,
                if (goals.isEmpty) const _NoGoals() else _Goals(goals),
              ],
            ),
    );
  }
}

Future<void> showPlanChooser(BuildContext context) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetTitle('Tambah rencana'),
          ListTile(
            leading: const Icon(Icons.event_repeat),
            title: const Text('Tagihan rutin baru'),
            subtitle: const Text('Kos, listrik, langganan, atau gaji. Diingatkan sebelum jatuh tempo'),
            onTap: () => Navigator.pop(context, 'bill'),
          ),
          ListTile(
            leading: const Icon(Icons.savings_outlined),
            title: const Text('Budget baru'),
            subtitle: const Text('Batas pengeluaran per minggu, bulan, atau tahun'),
            onTap: () => Navigator.pop(context, 'budget'),
          ),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('Goal tabungan baru'),
            subtitle: const Text('Target nominal, misalnya dana darurat atau HP baru'),
            onTap: () => Navigator.pop(context, 'goal'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  return switch (choice) {
    'bill' => showBillForm(context),
    'budget' => showBudgetForm(context),
    'goal' => showGoalForm(context),
    _ => null,
  };
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
    child: Row(
      children: [
        Expanded(child: Text(title, style: AppText.heading)),
        ?trailing,
      ],
    ),
  );
}

/// An empty section: what it is for, then the way to start.
class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.title, required this.text, required this.action, this.top});

  final String title;
  final String text;
  final Widget action;
  final Widget? top;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (top != null) ...[top!, const SizedBox(height: 14)],
          Text(title, style: AppText.bodyStrong),
          const SizedBox(height: 4),
          Text(text, style: AppText.label.copyWith(color: c.inkMuted, height: 1.4)),
          const SizedBox(height: 14),
          action,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- bills (A7)

class _Bills extends StatelessWidget {
  const _Bills(this.bills);

  final List<Map<String, dynamic>> bills;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final now = DateTime.now();
    // Unpaid this month: expense bills due before next month, late ones included.
    final (_, monthEnd) = periodRange('month', now);
    final unpaid = [
      for (final b in bills)
        if (b['type'] == 'expense' && DateTime.parse(b['next_due_date'] as String).isBefore(monthEnd)) b,
    ];
    final total = unpaid.fold<int>(0, (sum, b) => sum + (b['amount'] as int));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
            color: c.hero,
            borderRadius: BorderRadius.circular(AppRadius.hero),
            border: Theme.of(context).brightness == Brightness.dark ? Border.all(color: c.heroChip) : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tagihan belum dibayar · ${DateFormat('MMM', 'id_ID').format(now)}',
                      style: AppText.label.copyWith(color: c.onHeroMuted),
                    ),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text('Rp', style: AppText.body.copyWith(fontSize: 16, color: c.onHeroMuted)),
                          const SizedBox(width: 6),
                          Text(
                            NumberFormat.decimalPattern('id_ID').format(total / 100),
                            style: AppText.amountLg.copyWith(fontSize: 30, height: 1, color: c.onHero),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: c.heroChip, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  unpaid.isEmpty ? 'Lunas' : '${unpaid.length} tagihan',
                  style: AppText.caption.copyWith(fontWeight: FontWeight.w600, color: c.onHeroChip),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const _SectionTitle('Tagihan'),
        Material(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                for (final (i, b) in bills.indexed) ...[
                  if (i > 0) const Divider(indent: 16, endIndent: 16),
                  _BillRow(b, now: now),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BillRow extends StatelessWidget {
  const _BillRow(this.b, {required this.now});

  final Map<String, dynamic> b;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final due = DateTime.parse(b['next_due_date'] as String);
    final (days, level) = dueStatus(due, b['remind_days_before'] as int, now);
    final income = b['type'] == 'income';
    final late = level == DueLevel.overdue;
    final amount = formatAmount(b['amount'] as int);
    // The date block carries the state; the line under the name says it in words with an icon.
    final (blockBg, blockInk) = late
        ? (c.alertSoft, c.alert)
        : income
        ? (c.primarySoft, c.primary)
        : (c.surfaceMuted, c.ink);
    final status = income
        ? 'Pemasukan rutin · ${dueLabel(days).toLowerCase()}'
        : '${dueLabel(days).replaceFirst('Terlambat', 'Telat')} · $amount';
    final statusColor = late ? c.alert : c.inkMuted;
    final action = income ? 'Terima' : 'Bayar';
    return InkWell(
      onTap: () => payBill(context, b),
      onLongPress: () {
        haptic(Haptic.click);
        billOptions(context, b);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 50,
              decoration: BoxDecoration(color: blockBg, borderRadius: BorderRadius.circular(14)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${due.day}',
                    style: AppText.bodyStrong.copyWith(fontSize: 16, fontWeight: FontWeight.w700, color: blockInk),
                  ),
                  Text(
                    DateFormat('MMM', 'id_ID').format(due).toUpperCase(),
                    style: AppText.caption.copyWith(fontSize: 10, fontWeight: FontWeight.w600, color: blockInk),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(b['name'] as String, style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (level != DueLevel.upcoming) ...[
                        Icon(late ? Icons.error_outline : Icons.schedule, size: 13, color: statusColor),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: Text(
                          status,
                          style: AppText.caption.copyWith(
                            color: statusColor,
                            fontWeight: late ? FontWeight.w500 : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Due soon or late: the button to settle it. Later bills open the same form on tap.
            if (level == DueLevel.overdue)
              FilledButton(
                onPressed: () => payBill(context, b),
                style: FilledButton.styleFrom(minimumSize: const Size(64, 40), textStyle: AppText.label),
                child: Text(action),
              )
            else if (level == DueLevel.soon)
              OutlinedButton(
                onPressed: () => payBill(context, b),
                style: OutlinedButton.styleFrom(minimumSize: const Size(64, 40), textStyle: AppText.label),
                child: Text(action),
              )
            else if (income)
              Text('+$amount', style: AppText.amount.copyWith(fontSize: 14, color: c.income)),
          ],
        ),
      ),
    );
  }
}

class _NoBills extends StatelessWidget {
  const _NoBills();

  static const _suggestions = [
    ('Kos', 'expense'),
    ('Listrik', 'expense'),
    ('Internet', 'expense'),
    ('Langganan', 'expense'),
    ('Gaji', 'income'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Tagihan'),
        _EmptyCard(
          title: 'Belum ada tagihan rutin',
          text: 'Tambahkan sekali, nanti diingatkan sebelum jatuh tempo dan tinggal ketuk Bayar.',
          action: Wrap(
            spacing: AppSpace.tight,
            runSpacing: AppSpace.tight,
            children: [
              for (final (name, type) in _suggestions)
                ActionChip(
                  avatar: Icon(Icons.add, size: 16, color: type == 'income' ? c.primary : c.ink),
                  label: Text(name),
                  backgroundColor: type == 'income' ? c.primarySoft : null,
                  labelStyle: AppText.label.copyWith(fontSize: 14, color: type == 'income' ? c.primary : c.ink),
                  onPressed: () => showBillForm(context, name: name, type: type),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- budgets (A5)

class BudgetList extends StatelessWidget {
  const BudgetList(this.budgets, {super.key});

  final List<BudgetView> budgets;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final now = DateTime.now();
    final periods = {for (final b in budgets) b.row['period'] as String};
    // One period across the cards: the legend can say how far into it today is.
    final legend = periods.length == 1
        ? 'hari ini (${(periodElapsed(periods.first, now) * 100).round()}% ${_periodNouns[periods.first]})'
        : 'hari ini';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
          'Budget',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 2, height: 12, color: c.ink),
              const SizedBox(width: 6),
              Text(legend, style: AppText.caption.copyWith(color: c.inkMuted)),
            ],
          ),
        ),
        for (final (i, b) in budgets.indexed) ...[
          if (i > 0) const SizedBox(height: AppSpace.gap),
          _BudgetCard(b, now: now),
        ],
      ],
    );
  }
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard(this.b, {required this.now});

  final BudgetView b;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final limit = b.row['amount'] as int;
    final period = b.row['period'] as String;
    final level = budgetLevel(b.spent, limit);
    final used = limit == 0 ? 0.0 : b.spent / limit;
    final elapsed = periodElapsed(period, now);
    final over = level == BudgetLevel.over;
    // The fill carries severity, the track is a lighter step of it; the text says it in words.
    final (fill, track) = switch (level) {
      BudgetLevel.ok => (c.primary, c.primarySoft),
      BudgetLevel.warning => (VizColors.warning, VizColors.warning.withValues(alpha: 0.22)),
      BudgetLevel.over => (VizColors.critical, c.alertSoft),
    };
    final pace = used > elapsed ? 'lebih cepat dari jadwal' : 'sesuai jadwal';
    final status = over
        ? 'Lewat ${formatAmount(b.spent - limit)} dari batas ${formatAmount(limit)}'
        : '${formatAmount(b.spent)} dari ${formatAmount(limit)} · '
              '${level == BudgetLevel.warning ? 'hampir habis' : pace}';
    return Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () => _options(context),
        onLongPress: () {
          haptic(Haptic.click);
          _options(context);
        },
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.card),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Text(
                      b.row['name'] as String,
                      style: AppText.bodyStrong,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (period != 'month')
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(periodLabels[period]!, style: AppText.caption.copyWith(color: c.inkMuted)),
                    ),
                  Text(
                    percentOf(b.spent, limit),
                    style: AppText.label.copyWith(fontWeight: FontWeight.w600, color: over ? c.alert : c.ink),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Semantics(
                label: '${percentOf(b.spent, limit)} terpakai, ${(elapsed * 100).round()}% periode berjalan',
                excludeSemantics: true,
                child: SizedBox(
                  height: 20,
                  child: LayoutBuilder(
                    builder: (context, box) => Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        Container(
                          height: 12,
                          decoration: BoxDecoration(color: track, borderRadius: BorderRadius.circular(6)),
                        ),
                        Container(
                          width: box.maxWidth * used.clamp(0.0, 1.0),
                          height: 12,
                          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(6)),
                        ),
                        Positioned(
                          left: (box.maxWidth * elapsed - 1).clamp(0.0, box.maxWidth - 2),
                          top: 0,
                          bottom: 0,
                          child: Container(width: 2, color: c.ink),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (level != BudgetLevel.ok) ...[
                    Icon(over ? Icons.error_outline : Icons.warning_amber_rounded, size: 13, color: over ? c.alert : c.ink),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      status,
                      style: AppText.caption.copyWith(
                        color: over ? c.alert : c.inkMuted,
                        fontWeight: over ? FontWeight.w500 : null,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Change it, see what it counted, make it Beranda's daily allowance, or delete it.
  Future<void> _options(BuildContext context) async {
    final home = await getPref('home_budget') == b.row['id'];
    if (!context.mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitle(b.row['name'] as String),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Ubah budget'),
              subtitle: const Text('Batas, periode, kategori, dan label'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Lihat transaksi'),
              subtitle: const Text('Yang terhitung di periode ini'),
              onTap: () => Navigator.pop(context, 'records'),
            ),
            if (!home)
              ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: const Text('Jadikan jatah harian di Beranda'),
                onTap: () => Navigator.pop(context, 'home'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Hapus budget'),
              subtitle: const Text('Transaksinya tidak ikut terhapus'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (choice) {
      case 'edit':
        await showBudgetForm(context, budget: b.row);
      case 'records':
        await _showRecords(context);
      case 'home':
        await setPref('home_budget', b.row['id'] as String);
        if (context.mounted) showMessage(context, 'Jatah hari ini di Beranda sekarang mengikuti ${b.row['name']}.');
      case 'delete':
        await _confirmDelete(context);
    }
  }

  /// The expenses this budget counts in its current period, newest first.
  Future<void> _showRecords(BuildContext context) async {
    final (start, end) = periodRange(b.row['period'] as String, now);
    final rows = await db.getAll(
      '''
      SELECT r.amount, r.note, r.occurred_at, a.name AS account,
        (SELECT name FROM categories WHERE id = r.category_id) AS category
      $_budgetRecordsSql
      ORDER BY julianday(r.occurred_at) DESC''',
      [utcIso(start), utcIso(end), b.row['category_ids'] ?? '[]', b.row['account_ids'] ?? '[]', b.row['label_ids'] ?? '[]'],
    );
    if (!context.mounted) return;
    await showRecordsSheet(
      context,
      title: b.row['name'] as String,
      summary: '${rows.length} transaksi · ${formatAmount(b.spent)} dari ${formatAmount(b.row['amount'] as int)}',
      rows: rows,
      emptyText: 'Belum ada pengeluaran di periode ini.',
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

class NoBudgets extends StatelessWidget {
  const NoBudgets({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget bar(double width) => FractionallySizedBox(
      widthFactor: width,
      alignment: Alignment.centerLeft,
      child: Container(
        height: 12,
        decoration: BoxDecoration(color: c.surfaceMuted, borderRadius: BorderRadius.circular(6)),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Budget'),
        _EmptyCard(
          top: ExcludeSemantics(child: Column(children: [bar(1), const SizedBox(height: 8), bar(0.7)])),
          title: 'Belum ada budget',
          text: 'Belum tahu angkanya? Catat dulu sebulan, lalu pakai pengeluaran per kategori di Laporan sebagai patokan.',
          action: OutlinedButton(onPressed: () => showBudgetForm(context), child: const Text('Buat budget')),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- saving goals (A6)

class _Goals extends StatelessWidget {
  const _Goals(this.goals);

  final List<Map<String, dynamic>> goals;

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (var i = 0; i < goals.length; i += 2) goals.sublist(i, (i + 2).clamp(0, goals.length)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Goal tabungan'),
        for (final (i, pair) in rows.indexed) ...[
          if (i > 0) const SizedBox(height: AppSpace.gap),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _GoalCard(pair.first)),
                const SizedBox(width: AppSpace.gap),
                Expanded(child: pair.length > 1 ? _GoalCard(pair.last) : const SizedBox()),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard(this.g);

  final Map<String, dynamic> g;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final saved = g['saved'] as int;
    final target = g['target_amount'] as int;
    final targetDate = g['target_date'] == null ? null : DateTime.parse(g['target_date'] as String);
    final plan = planGoal(saved: saved, target: target, targetDate: targetDate, now: DateTime.now());
    final paused = g['state'] == 'paused';
    final active = !paused && !plan.reached;
    // Active goals sit on the soft green; paused ones go grey, so the eye lands on what is running.
    final (bg, track, fill, muted) = active
        ? (c.primarySoft, c.surface, c.primary, c.onPrimarySoft)
        : (c.surface, c.surfaceMuted, paused ? c.outline : c.primary, c.inkMuted);
    final compact = NumberFormat.compact(locale: 'id_ID');
    final (statusIcon, status) = plan.reached
        ? (Icons.check_circle_outline, 'Tercapai')
        : paused
        ? (Icons.pause_circle_outline, 'Dijeda')
        : plan.late
        ? (Icons.warning_amber_rounded, 'Lewat tanggal target')
        : targetDate != null
        ? (null, 'Target ${DateFormat('MMM yyyy', 'id_ID').format(targetDate)}')
        : (null, 'Sisa ${formatAmount(plan.remaining)}');
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onLongPress: () {
          haptic(Haptic.click);
          _options(context, paused);
        },
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.card),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(g['name'] as String, style: AppText.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 12),
              Text(percentOf(saved.clamp(0, target), target), style: AppText.title.copyWith(fontSize: 20)),
              Text(
                'Rp ${compact.format(saved / 100)} / ${compact.format(target / 100)}',
                style: AppText.caption.copyWith(color: muted),
              ),
              const SizedBox(height: 12),
              Semantics(
                label: '${percentOf(saved, target)} terkumpul, $status',
                excludeSemantics: true,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: plan.progress,
                    minHeight: 8,
                    backgroundColor: track,
                    color: fill,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (statusIcon != null) ...[Icon(statusIcon, size: 13, color: muted), const SizedBox(width: 4)],
                  Expanded(child: Text(status, style: AppText.caption.copyWith(color: muted))),
                ],
              ),
              const Spacer(),
              const SizedBox(height: 12),
              if (active && g['account_id'] != null)
                FilledButton(
                  // A transfer into the goal's account keeps every balance right.
                  onPressed: () => showRecordForm(
                    context,
                    prefill: Prefill(
                      type: 'transfer',
                      transferAccountId: g['account_id'] as String,
                      note: 'Tabungan ${g['name']}',
                    ),
                  ),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(40), textStyle: AppText.label),
                  child: const Text('Tambah'),
                )
              else if (paused)
                OutlinedButton(
                  onPressed: () => _setState(paused: false),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(40), textStyle: AppText.label),
                  child: const Text('Lanjutkan'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _setState({required bool paused}) => db.execute(
    'UPDATE goals SET state = ?, updated_at = ? WHERE id = ?',
    [paused ? 'paused' : 'active', nowIso(), g['id']],
  );

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
      await _setState(paused: !paused);
    } else if (choice == 'delete') {
      await db.execute('DELETE FROM goals WHERE id = ?', [g['id']]);
    }
  }
}

class _NoGoals extends StatelessWidget {
  const _NoGoals();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Goal tabungan'),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
          decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(AppRadius.card)),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle),
                child: Icon(Icons.track_changes, color: c.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Punya target?', style: AppText.bodyStrong),
                    const SizedBox(height: 4),
                    Text(
                      'Misalnya dana darurat atau HP baru',
                      style: AppText.label.copyWith(color: c.onPrimarySoft, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => showGoalForm(context),
                style: FilledButton.styleFrom(minimumSize: const Size(64, 44), textStyle: AppText.label),
                child: const Text('Buat goal'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

const _newAccount = '__new';

Future<void> showGoalForm(BuildContext context) async {
  final accounts = await db.getAll("SELECT id, name FROM accounts WHERE archived = 0 ORDER BY type != 'savings', name");
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
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
  final _nameFocus = FocusNode();
  final _targetFocus = FocusNode();
  final _savedFocus = FocusNode();
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
    haptic(Haptic.click); // saved
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    _saved.dispose();
    _nameFocus.dispose();
    _targetFocus.dispose();
    _savedFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final date = _date;
    final newAccount = _accountId == _newAccount;
    return FormSheet(
      title: 'Goal tabungan baru',
      action: FilledButton(
        onPressed: _save,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
        child: const Text('Simpan'),
      ),
      children: [
        FormCard(
          children: [
            FormRow(
              icon: Icons.edit_outlined,
              label: 'Nama goal',
              focusNode: _nameFocus,
              child: TextField(
                controller: _name,
                focusNode: _nameFocus,
                autofocus: true,
                style: AppText.body.copyWith(fontWeight: FontWeight.w500),
                decoration: bareField('contoh: Dana darurat'),
              ),
            ),
            FormRow(
              icon: Icons.flag_outlined,
              strong: true,
              label: 'Target',
              focusNode: _targetFocus,
              child: MoneyField(controller: _target, focusNode: _targetFocus),
            ),
            FormRow(
              icon: Icons.account_balance_wallet_outlined,
              label: 'Simpan di akun',
              value: newAccount
                  ? 'Akun tabungan baru'
                  : widget.accounts.firstWhere((a) => a['id'] == _accountId)['name'] as String,
              onTap: () async {
                final id = await chooseOne(context, 'Simpan di akun', [
                  (_newAccount, 'Akun tabungan baru', null),
                  for (final a in widget.accounts) (a['id'] as String, a['name'] as String, null),
                ], _accountId);
                if (id != null) setState(() => _accountId = id);
              },
            ),
            if (newAccount)
              FormRow(
                icon: Icons.savings_outlined,
                label: 'Sudah terkumpul (opsional)',
                focusNode: _savedFocus,
                child: MoneyField(controller: _saved, focusNode: _savedFocus),
              ),
            FormRow(
              icon: Icons.calendar_today_outlined,
              label: 'Tanggal target (opsional)',
              value: date == null ? 'Tanpa tanggal' : DateFormat('d MMMM yyyy', 'id_ID').format(date),
              trailing: date == null
                  ? null
                  : IconButton(
                      icon: Icon(Icons.close, size: 18, color: c.inkMuted),
                      tooltip: 'Hapus tanggal',
                      onPressed: () => setState(() => _date = null),
                    ),
              chevron: date == null,
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
          ],
        ),
        if (!newAccount)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('Progres goal mengikuti saldo akun ini.', style: AppText.caption.copyWith(color: c.inkMuted)),
          ),
      ],
    );
  }
}

/// A new budget, or with [budget] (its row) that budget to change.
Future<void> showBudgetForm(BuildContext context, {Map<String, dynamic>? budget}) async {
  final categories = await db.getAll(
    "SELECT id, name FROM categories WHERE type = 'expense' AND archived = 0 ORDER BY name",
  );
  final labels = await db.getAll('SELECT id, name FROM labels ORDER BY name COLLATE NOCASE');
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => BudgetForm(categories: categories, labels: labels, budget: budget),
  );
}

class BudgetForm extends StatefulWidget {
  const BudgetForm({super.key, required this.categories, required this.labels, this.budget});

  final List<Map<String, dynamic>> categories;
  final List<Map<String, dynamic>> labels;
  final Map<String, dynamic>? budget; // the budget being changed; null for a new one

  @override
  State<BudgetForm> createState() => _BudgetFormState();
}

class _BudgetFormState extends State<BudgetForm> {
  final _name = TextEditingController();
  final _amount = TextEditingController();
  final _nameFocus = FocusNode();
  final _amountFocus = FocusNode();
  String _period = 'month';
  final _selected = <String>{};
  var _labelIds = <String>{};

  @override
  void initState() {
    super.initState();
    if (widget.budget case final b?) {
      Set<String> ids(Object? raw) => raw is String && raw.isNotEmpty ? {...(jsonDecode(raw) as List).cast<String>()} : {};
      _name.text = b['name'] as String;
      _amount.text = NumberFormat.decimalPattern('id_ID').format((b['amount'] as int) / 100);
      _period = periodLabels.containsKey(b['period']) ? b['period'] as String : 'month';
      _selected.addAll(ids(b['category_ids']));
      _labelIds = ids(b['label_ids']);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _nameFocus.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = parseAmount(_amount.text);
    if (amount == null) return showMessage(context, 'Batas tidak valid. Contoh: 1.500.000');
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
    if (widget.budget case final b?) {
      await db.execute(
        '''
        UPDATE budgets SET name = ?, period = ?, amount = ?, category_ids = ?, label_ids = ?, updated_at = ?
        WHERE id = ?''',
        [name, _period, amount, jsonEncode([..._selected]), jsonEncode([..._labelIds]), now, b['id']],
      );
      haptic(Haptic.click); // saved
    if (mounted) Navigator.pop(context);
      return;
    }
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
    haptic(Haptic.click); // saved
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return FormSheet(
      title: widget.budget == null ? 'Budget baru' : 'Ubah budget',
      action: FilledButton(
        onPressed: _save,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
        child: const Text('Simpan'),
      ),
      children: [
        PillSwitch(
          options: [for (final e in periodLabels.entries) (e.key, e.value)],
          value: _period,
          onChanged: (p) => setState(() => _period = p),
        ),
        FormCard(
          children: [
            FormRow(
              icon: Icons.savings_outlined,
              strong: true,
              label: 'Batas pengeluaran',
              focusNode: _amountFocus,
              child: MoneyField(controller: _amount, focusNode: _amountFocus, autofocus: widget.budget == null),
            ),
            FormRow(
              icon: Icons.edit_outlined,
              label: 'Nama (opsional)',
              focusNode: _nameFocus,
              child: TextField(
                controller: _name,
                focusNode: _nameFocus,
                style: AppText.body.copyWith(fontWeight: FontWeight.w500),
                decoration: bareField('contoh: Makan bulanan'),
              ),
            ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const FormLabel('Kategori, kosongkan untuk semua pengeluaran'),
            Wrap(
              spacing: AppSpace.tight,
              runSpacing: AppSpace.tight,
              children: [
                for (final x in widget.categories)
                  FilterChip(
                    label: Text(x['name'] as String),
                    selected: _selected.contains(x['id']),
                    showCheckmark: false,
                    labelStyle: AppText.label.copyWith(
                      fontSize: 14,
                      color: _selected.contains(x['id']) ? c.onPrimary : c.ink,
                    ),
                    onSelected: (on) =>
                        setState(() => on ? _selected.add(x['id'] as String) : _selected.remove(x['id'])),
                  ),
              ],
            ),
          ],
        ),
        if (widget.labels.isNotEmpty)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const FormLabel('Label, opsional: hanya transaksi berlabel ini'),
              LabelChips(labels: widget.labels, selected: _labelIds, onChanged: (ids) => _labelIds = ids),
            ],
          ),
      ],
    );
  }
}
