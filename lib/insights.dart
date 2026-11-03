import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'db.dart';
import 'money.dart';
import 'reports.dart';

// A11 cashflow report and A5 budgets.

/// Chart colors from the dataviz reference palette, validated against this app's card surfaces
/// (light #eff5f2, dark #161d1c): categorical slots 1-3 pass the all-pairs CVD and normal-vision
/// checks in both modes. Light orange/aqua sit below 3:1, so every colored part is listed with its
/// name and amount beside it.
class VizColors {
  const VizColors._(this.bar, this.needLevels, this.good);

  final Color bar; // single-series bars and the "on track" meter (categorical slot 1)
  final Map<String?, Color> needLevels; // must / need / want = slots 1-3; no level = de-emphasis gray
  final Color good; // delta text when the change is good

  static const warning = Color(0xFFFAB219); // status palette: fixed, never themed
  static const critical = Color(0xFFD03B3B);

  static VizColors of(BuildContext context) => Theme.of(context).brightness == Brightness.dark
      ? const VizColors._(Color(0xFF3987E5), {
          'must': Color(0xFF3987E5),
          'need': Color(0xFFD95926),
          'want': Color(0xFF199E70),
          null: Color(0xFF898781),
        }, Color(0xFF0CA30C))
      : const VizColors._(Color(0xFF2A78D6), {
          'must': Color(0xFF2A78D6),
          'need': Color(0xFFEB6834),
          'want': Color(0xFF1BAF7A),
          null: Color(0xFF898781),
        }, Color(0xFF006300));
}

const needLevelLabels = {'must': 'Wajib', 'need': 'Butuh', 'want': 'Ingin', null: 'Belum diberi level'};

String _iso(DateTime local) => local.toUtc().toIso8601String();

String _percent(int part, int whole) => whole == 0 ? '0%' : '${(part * 100 / whole).round()}%';

// ---------------------------------------------------------------- report (A11)

class ReportTab extends StatefulWidget {
  const ReportTab({super.key});

  @override
  State<ReportTab> createState() => _ReportTabState();
}

class _ReportTabState extends State<ReportTab> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  late Stream<MonthReport> _report = _watch();

  // One query covers this month and the previous one; julianday() compares instants, not strings.
  static const _sql = '''
    SELECT r.type, r.category_id, c.name, c.need_level,
      SUM(CASE WHEN julianday(r.occurred_at) >= julianday(?2) THEN r.amount ELSE 0 END) AS cur,
      SUM(CASE WHEN julianday(r.occurred_at) < julianday(?2) THEN r.amount ELSE 0 END) AS prev
    FROM records r
    JOIN accounts a ON a.id = r.account_id
    LEFT JOIN categories c ON c.id = r.category_id
    WHERE r.status = 'confirmed' AND a.exclude_from_stats = 0 AND r.type IN ('income', 'expense')
      AND julianday(r.occurred_at) >= julianday(?1) AND julianday(r.occurred_at) < julianday(?3)
    GROUP BY r.type, r.category_id''';

  Stream<MonthReport> _watch() {
    final (start, end) = periodRange('month', _month);
    final previous = DateTime(_month.year, _month.month - 1);
    return db
        .watch(_sql, parameters: [_iso(previous), _iso(start), _iso(end)])
        .map((rows) => buildMonthReport(rows.toList()));
  }

  void _shift(int months) => setState(() {
    _month = DateTime(_month.year, _month.month + months);
    _report = _watch();
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isCurrent = _month.year == now.year && _month.month == now.month;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(icon: const Icon(Icons.chevron_left), tooltip: 'Bulan sebelumnya', onPressed: () => _shift(-1)),
            Text(DateFormat('MMMM yyyy', 'id_ID').format(_month), style: Theme.of(context).textTheme.titleMedium),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Bulan berikutnya',
              onPressed: isCurrent ? null : () => _shift(1),
            ),
          ],
        ),
        Expanded(
          child: StreamBuilder(
            stream: _report,
            builder: (context, snap) {
              final r = snap.data;
              if (r == null) return const Center(child: CircularProgressIndicator());
              if (r.isEmpty) return const Center(child: Text('Belum ada transaksi di bulan ini.'));
              return ListView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 88),
                children: [_Kpis(r), if (r.expense > 0) _NeedSplit(r), if (r.categories.isNotEmpty) _CategoryBars(r)],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Kpis extends StatelessWidget {
  const _Kpis(this.r);

  final MonthReport r;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _StatTile('Pemasukan', formatCompact(r.income), percentChange(r.income, r.previousIncome), upIsGood: true),
            _StatTile('Pengeluaran', formatCompact(r.expense), percentChange(r.expense, r.previousExpense)),
            _StatTile('Selisih', '${r.net < 0 ? '-' : '+'}${formatCompact(r.net.abs())}', null),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            'Persentase dibanding bulan sebelumnya',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile(this.label, this.value, this.delta, {this.upIsGood = false});

  final String label;
  final String value;
  final double? delta;
  final bool upIsGood;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final d = delta;
    // Delta color = direction x whether up is good; the arrow keeps it readable without color.
    final deltaColor = d == null || d.round() == 0
        ? muted
        : (d > 0) == upIsGood
        ? VizColors.of(context).good
        : theme.colorScheme.error;
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.labelMedium?.copyWith(color: muted)),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 2),
              if (d == null)
                Text('–', style: theme.textTheme.labelSmall?.copyWith(color: muted))
              else
                Row(
                  children: [
                    Icon(
                      d.round() == 0 ? Icons.remove : (d > 0 ? Icons.arrow_upward : Icons.arrow_downward),
                      size: 12,
                      color: deltaColor,
                    ),
                    Text('${d.abs().round()}%', style: theme.textTheme.labelSmall?.copyWith(color: deltaColor)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Thin segmented bar (8px, rounded ends, 2px gaps) above a list that carries every figure.
class _NeedSplit extends StatelessWidget {
  const _NeedSplit(this.r);

  final MonthReport r;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = VizColors.of(context).needLevels;
    final parts = [
      for (final level in const ['must', 'need', 'want', null])
        if ((r.byNeedLevel[level] ?? 0) > 0) (level, r.byNeedLevel[level]!),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Wajib, butuh, atau ingin', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            Semantics(
              label: parts
                  .map((p) => '${needLevelLabels[p.$1]} ${formatAmount(p.$2)}, ${_percent(p.$2, r.expense)}')
                  .join('; '),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  height: 8,
                  child: Row(
                    // Without stretch the childless ColoredBoxes get a loose height and collapse to 0px.
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, p) in parts.indexed) ...[
                        if (i > 0) const SizedBox(width: 2),
                        Expanded(
                          flex: (p.$2 * 1000 / r.expense).round().clamp(1, 1000),
                          child: ColoredBox(color: colors[p.$1]!),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            for (final p in parts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: colors[p.$1], borderRadius: BorderRadius.circular(2)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(needLevelLabels[p.$1]!)),
                    Text(formatAmount(p.$2)),
                    SizedBox(
                      width: 48,
                      child: Text(
                        _percent(p.$2, r.expense),
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Ranked horizontal bars, largest first, one hue: one series, so no legend.
class _CategoryBars extends StatelessWidget {
  const _CategoryBars(this.r);

  final MonthReport r;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = VizColors.of(context).bar;
    final max = r.categories.first.amount;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Pengeluaran per kategori', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            for (final c in r.categories)
              Tooltip(
                message: '${c.name}: ${formatAmount(c.amount)} (${_percent(c.amount, r.expense)})',
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(c.name, overflow: TextOverflow.ellipsis)),
                          Text(formatAmount(c.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
                          SizedBox(
                            width: 48,
                            child: Text(
                              _percent(c.amount, r.expense),
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      LayoutBuilder(
                        builder: (context, box) => Container(
                          width: (box.maxWidth * c.amount / max).clamp(2, box.maxWidth),
                          height: 8,
                          decoration: BoxDecoration(
                            color: color,
                            // Square at the baseline, 4px rounded at the data end.
                            borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- budgets (A5)

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
  // towards statistics, limited to the budget's categories and accounts (empty list = all).
  // ponytail: label filters are stored but not applied; no screen sets them yet.
  static const _spentSql = '''
    SELECT COALESCE(SUM(r.amount), 0) AS spent
    FROM records r JOIN accounts a ON a.id = r.account_id
    WHERE r.type = 'expense' AND r.status = 'confirmed' AND a.exclude_from_stats = 0
      AND julianday(r.occurred_at) >= julianday(?1) AND julianday(r.occurred_at) < julianday(?2)
      AND (json_array_length(?3) = 0 OR r.category_id IN (SELECT value FROM json_each(?3)))
      AND (json_array_length(?4) = 0 OR r.account_id IN (SELECT value FROM json_each(?4)))''';

  Stream<List<_BudgetView>> _watch() => db
      .watch('SELECT * FROM budgets ORDER BY name', triggerOnTables: const ['budgets', 'records', 'accounts'])
      .asyncMap((rows) async {
        final now = DateTime.now();
        return [
          for (final b in rows)
            await () async {
              final (start, end) = periodRange(b['period'] as String, now);
              final spent = await db.get(_spentSql, [
                _iso(start),
                _iso(end),
                b['category_ids'] ?? '[]',
                b['account_ids'] ?? '[]',
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
        if (budgets == null) return const Center(child: CircularProgressIndicator());
        if (budgets.isEmpty) return const Center(child: Text('Belum ada budget. Tekan + untuk membuat.'));
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
          children: [for (final b in budgets) _BudgetCard(b)],
        );
      },
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
              Semantics(
                label: '${_percent(b.spent, limit)} terpakai, $status',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    height: 8,
                    color: fill.withValues(alpha: 0.22),
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      heightFactor: 1, // a childless ColoredBox would otherwise collapse to 0px tall
                      widthFactor: limit == 0 ? 0 : (b.spent / limit).clamp(0.0, 1.0),
                      child: ColoredBox(color: fill),
                    ),
                  ),
                ),
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
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => BudgetForm(categories: categories),
  );
}

class BudgetForm extends StatefulWidget {
  const BudgetForm({super.key, required this.categories});

  final List<Map<String, dynamic>> categories;

  @override
  State<BudgetForm> createState() => _BudgetFormState();
}

class _BudgetFormState extends State<BudgetForm> {
  final _name = TextEditingController();
  final _amount = TextEditingController();
  String _period = 'month';
  final _selected = <String>{};

  Future<void> _save() async {
    final amount = parseAmount(_amount.text);
    if (amount == null) return _message(context, 'Batas tidak valid. Contoh: 1,5jt atau 500rb');
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
      VALUES (uuid(), ?, ?, ?, ?, 'IDR', ?, ?, '[]', '[]', ?, ?)''',
      [
        currentUserId,
        name,
        _period,
        amount,
        DateFormat('yyyy-MM-dd').format(start),
        jsonEncode([..._selected]),
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
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Simpan')),
        ],
      ),
    );
  }
}

void _message(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
