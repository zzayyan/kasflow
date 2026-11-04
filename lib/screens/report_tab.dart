import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../money.dart';
import '../reports.dart';
import '../ui.dart';

// A11 cashflow report.

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
      AND (?4 IS NULL OR EXISTS (SELECT 1 FROM json_each(r.label_ids) l WHERE l.value = ?4))
    GROUP BY r.type, r.category_id''';

  String? _labelId; // null = all records; otherwise only records with this label, e.g. a trip
  final _labels = db.watch('SELECT id, name FROM labels ORDER BY name COLLATE NOCASE');

  Stream<MonthReport> _watch() {
    final (start, end) = periodRange('month', _month);
    final previous = DateTime(_month.year, _month.month - 1);
    return db
        .watch(_sql, parameters: [utcIso(previous), utcIso(start), utcIso(end), _labelId])
        .map((rows) => buildMonthReport(rows.toList()));
  }

  void _shift(int months) => setState(() {
    _month = DateTime(_month.year, _month.month + months);
    _report = _watch();
  });

  void _filter(String? labelId) => setState(() {
    _labelId = labelId;
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
        StreamBuilder(
          stream: _labels,
          builder: (context, snap) {
            final labels = snap.data;
            if (labels == null || labels.isEmpty) return const SizedBox.shrink();
            // A deleted label can't stay selected: fall back to all records.
            final value = labels.any((l) => l['id'] == _labelId) ? _labelId : null;
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: DropdownButtonFormField<String?>(
                initialValue: value,
                isDense: true,
                decoration: const InputDecoration(labelText: 'Label', border: OutlineInputBorder(), isDense: true),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Semua transaksi')),
                  for (final l in labels) DropdownMenuItem(value: l['id'] as String, child: Text('#${l['name']}')),
                ],
                onChanged: _filter,
              ),
            );
          },
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
                  .map((p) => '${needLevelLabels[p.$1]} ${formatAmount(p.$2)}, ${percentOf(p.$2, r.expense)}')
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
                        percentOf(p.$2, r.expense),
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
                message: '${c.name}: ${formatAmount(c.amount)} (${percentOf(c.amount, r.expense)})',
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
                              percentOf(c.amount, r.expense),
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
