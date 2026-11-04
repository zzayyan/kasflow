import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../money.dart';
import '../reports.dart';
import '../theme.dart';
import '../ui.dart';
import 'plans_tab.dart';

// A11 cashflow report, after the "E · Laporan" artboard of the Cashflow UI/UX canvas.

const _trendMonths = 6;
const _allLabels = ''; // menu value for "every label" (a null value would read as dismissed)
final _compact = NumberFormat.compact(locale: 'id_ID');

class ReportTab extends StatefulWidget {
  const ReportTab({super.key, this.labelId});

  /// Start filtered to this label, e.g. opened from Kelola label.
  final String? labelId;

  @override
  State<ReportTab> createState() => _ReportTabState();
}

class _ReportTabState extends State<ReportTab> {
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

  // The trend window's records; they are bucketed into local months in Dart (monthTotals).
  static const _trendSql = '''
    SELECT r.type, r.amount, r.occurred_at
    FROM records r JOIN accounts a ON a.id = r.account_id
    WHERE r.status = 'confirmed' AND a.exclude_from_stats = 0 AND r.type IN ('income', 'expense')
      AND julianday(r.occurred_at) >= julianday(?1) AND julianday(r.occurred_at) < julianday(?2)
      AND (?3 IS NULL OR EXISTS (SELECT 1 FROM json_each(r.label_ids) l WHERE l.value = ?3))''';

  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  String _view = 'expense'; // 'expense' | 'income' | 'budget'
  late String? _labelId = widget.labelId; // null = all records; else only records with this label

  MonthReport? _report;
  List<Map<String, dynamic>> _trendRows = const [];
  List<Map<String, dynamic>> _labels = const [];
  List<BudgetView>? _budgets;
  final _subs = <StreamSubscription<void>>[];
  final _monthSubs = <StreamSubscription<void>>[];

  void _set(VoidCallback change) {
    if (mounted) setState(change);
  }

  /// The trend ends at the current month, unless the chosen month is further back than it shows.
  DateTime get _trendEnd {
    final now = DateTime.now();
    final current = DateTime(now.year, now.month);
    return _month.isBefore(DateTime(now.year, now.month - (_trendMonths - 1))) ? _month : current;
  }

  void _watchMonth() {
    for (final s in _monthSubs) {
      unawaited(s.cancel());
    }
    _monthSubs.clear();
    final (start, end) = periodRange('month', _month);
    final previous = DateTime(_month.year, _month.month - 1);
    final trendEnd = _trendEnd;
    final trendStart = DateTime(trendEnd.year, trendEnd.month - (_trendMonths - 1));
    _monthSubs.addAll([
      db
          .watch(_sql, parameters: [utcIso(previous), utcIso(start), utcIso(end), _labelId])
          .listen((rows) => _set(() => _report = buildMonthReport(rows.toList()))),
      db
          .watch(_trendSql, parameters: [utcIso(trendStart), utcIso(DateTime(trendEnd.year, trendEnd.month + 1)), _labelId])
          .listen((rows) => _set(() => _trendRows = rows)),
    ]);
  }

  @override
  void initState() {
    super.initState();
    _subs.addAll([
      db.watch('SELECT id, name FROM labels ORDER BY name COLLATE NOCASE').listen((rows) {
        _set(() {
          _labels = rows;
          // A deleted label can't stay selected: fall back to all records.
          if (_labelId != null && !rows.any((l) => l['id'] == _labelId)) {
            _labelId = null;
            _watchMonth();
          }
        });
      }),
      watchBudgets().listen((rows) => _set(() => _budgets = rows)),
    ]);
    _watchMonth();
  }

  @override
  void dispose() {
    for (final s in [..._subs, ..._monthSubs]) {
      unawaited(s.cancel());
    }
    super.dispose();
  }

  void _showMonth(DateTime month) => setState(() {
    _month = month;
    _watchMonth();
  });

  void _filter(String? labelId) => setState(() {
    _labelId = labelId;
    _watchMonth();
  });

  Future<void> _pickMonth() async {
    final now = DateTime.now();
    final months = [for (var i = 0; i < 24; i++) DateTime(now.year, now.month - i)];
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text('Pilih bulan', style: AppText.heading),
              ),
              for (final m in months)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  title: Text(DateFormat('MMMM yyyy', 'id_ID').format(m), style: AppText.body),
                  selected: m == _month,
                  onTap: () => Navigator.pop(context, m),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) _showMonth(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final now = DateTime.now();
    final isCurrent = _month.year == now.year && _month.month == now.month;
    final monthName = DateFormat('MMMM', 'id_ID').format(_month);
    final r = _report;
    final budgets = _budgets;
    final income = _view == 'income';
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 16, AppSpace.page, 24),
        children: [
          Row(
            children: [
              // Pushed on its own (from Kelola label) it needs a way back; as a tab it has none.
              if (ModalRoute.of(context)?.canPop ?? false) ...[
                IconButton(
                  tooltip: 'Kembali',
                  onPressed: () => Navigator.pop(context),
                  style: IconButton.styleFrom(backgroundColor: c.surface, fixedSize: const Size.square(46)),
                  icon: Icon(Icons.chevron_left, color: c.ink),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Laporan', style: AppText.title),
                    if (!isCurrent)
                      Text(
                        DateFormat('MMMM yyyy', 'id_ID').format(_month),
                        style: AppText.label.copyWith(color: c.inkMuted),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Pilih bulan',
                onPressed: _pickMonth,
                style: IconButton.styleFrom(backgroundColor: c.surface, fixedSize: const Size.square(46)),
                icon: Icon(Icons.calendar_today_outlined, size: 20, color: c.ink),
              ),
            ],
          ),
          const SizedBox(height: 16),
          PillSwitch(
            options: const [('expense', 'Pengeluaran'), ('income', 'Pemasukan'), ('budget', 'Budget')],
            value: _view,
            fontSize: 14,
            onChanged: (v) => setState(() => _view = v),
          ),
          const SizedBox(height: 16),
          if (_view == 'budget') ...[
            if (budgets == null)
              const SizedBox.shrink()
            else if (budgets.isEmpty)
              const NoBudgets()
            else
              BudgetList(budgets),
            const SizedBox(height: AppSpace.gap),
            Text(
              'Budget selalu menghitung periode yang sedang berjalan.',
              style: AppText.caption.copyWith(color: c.inkMuted),
            ),
          ] else if (r == null)
            const Center(child: CircularProgressIndicator())
          else ...[
            Row(
              children: [
                Expanded(child: _Kpi('Masuk $monthName', r.income, color: c.income)),
                const SizedBox(width: 10),
                Expanded(child: _Kpi('Keluar $monthName', r.expense)),
              ],
            ),
            const SizedBox(height: 16),
            _CategoryCard(
              categories: income ? r.incomeCategories : r.categories,
              total: income ? r.income : r.expense,
              caption: income ? 'Total masuk' : 'Total keluar',
              chartLabel: '${income ? 'Pemasukan' : 'Pengeluaran'} $monthName per kategori',
              emptyText: 'Belum ada ${income ? 'pemasukan' : 'pengeluaran'} di $monthName',
              labels: _labels,
              labelId: _labelId,
              onLabel: _filter,
            ),
            if (!income && isCurrent && budgets != null && budgets.isNotEmpty) ...[
              const SizedBox(height: 16),
              _BudgetHint(budgets, onTap: () => setState(() => _view = 'budget')),
            ],
            if (!income && r.expense > 0) ...[const SizedBox(height: 16), _NeedSplit(r)],
            const SizedBox(height: 16),
            _Trend(
              title: income ? 'Tren pemasukan' : 'Tren pengeluaran',
              totals: monthTotals(_trendRows, _trendEnd, _trendMonths, _view),
              end: _trendEnd,
              selected: _month,
              onSelect: _showMonth,
            ),
          ],
        ],
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.amount, {this.color});

  final String label;
  final int amount;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.tile)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.caption.copyWith(color: c.inkMuted)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              formatAmount(amount),
              style: AppText.amount.copyWith(fontSize: 18, color: color ?? c.ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
    decoration: BoxDecoration(color: AppColors.of(context).surface, borderRadius: BorderRadius.circular(AppRadius.hero)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );
}

// ---------------------------------------------------------------- per category: donut + legend

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.categories,
    required this.total,
    required this.caption,
    required this.chartLabel,
    required this.emptyText,
    required this.labels,
    required this.labelId,
    required this.onLabel,
  });

  final List<CategoryTotal> categories; // largest first
  final int total;
  final String caption;
  final String chartLabel;
  final String emptyText;
  final List<Map<String, dynamic>> labels;
  final String? labelId;
  final ValueChanged<String?> onLabel;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // Five hues and a gray for the rest. ponytail: colors follow rank within this month, so a
    // category can change color between months; stable colors need a slot per category.
    final parts = foldSmallest(categories, c.chart.length);
    // Past the five hues (the folded rest, or a sixth part left unfolded) comes the gray.
    final colors = [for (var i = 0; i < parts.length; i++) i < c.chart.length ? c.chart[i] : c.chartOther];
    final half = (parts.length / 2).ceil();
    final labelName = labels.where((l) => l['id'] == labelId).firstOrNull?['name'];
    Widget legend(int i) {
      final p = parts[i];
      return Tooltip(
        message: '${p.name}: ${formatAmount(p.amount)}',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: colors[i], shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(p.name, style: AppText.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              Text(percentOf(p.amount, total), style: AppText.label.copyWith(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );
    }

    return _Card(
      children: [
        Row(
          children: [
            Expanded(child: Text('Per kategori', style: AppText.heading.copyWith(fontSize: 16))),
            if (labels.isNotEmpty)
              PopupMenuButton<String>(
                tooltip: 'Saring dengan label',
                initialValue: labelId ?? _allLabels,
                onSelected: (id) => onLabel(id == _allLabels ? null : id),
                itemBuilder: (context) => [
                  const PopupMenuItem(value: _allLabels, child: Text('Semua label')),
                  for (final l in labels) PopupMenuItem(value: l['id'] as String, child: Text('#${l['name']}')),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        labelName == null ? 'Semua label' : '#$labelName',
                        style: AppText.label.copyWith(color: c.inkMuted),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.expand_more, size: 16, color: c.inkMuted),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (parts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              '$emptyText.',
              textAlign: TextAlign.center,
              style: AppText.label.copyWith(color: c.inkMuted),
            ),
          )
        else ...[
          Center(
            child: Semantics(
              label: '$chartLabel, total ${formatAmount(total)}',
              excludeSemantics: true,
              child: SizedBox.square(
                dimension: 200,
                child: CustomPaint(
                  painter: _DonutPainter([for (final p in parts) p.amount], colors),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Rp ${_compact.format(total / 100)}',
                          style: AppText.title.copyWith(fontSize: 22, letterSpacing: -0.3),
                        ),
                        const SizedBox(height: 2),
                        Text(caption, style: AppText.caption.copyWith(color: c.inkMuted)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Column-major, like the design: the largest run down the left.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Column(children: [for (var i = 0; i < half; i++) legend(i)])),
              const SizedBox(width: 18),
              Expanded(child: Column(children: [for (var i = half; i < parts.length; i++) legend(i)])),
            ],
          ),
        ],
      ],
    );
  }
}

/// A ring of [values] from 12 o'clock clockwise, each part split from the next by a 2px gap.
class _DonutPainter extends CustomPainter {
  const _DonutPainter(this.values, this.colors);

  final List<int> values;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 24.0;
    final radius = size.shortestSide / 2 - 6 - stroke / 2;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: radius);
    final total = values.fold<int>(0, (sum, v) => sum + v);
    if (total <= 0) return;
    final gapAngle = values.length > 1 ? 2 / radius : 0.0; // 2px of arc
    var start = -math.pi / 2;
    for (final (i, v) in values.indexed) {
      final sweep = v / total * 2 * math.pi;
      final drawn = sweep - gapAngle;
      if (drawn > 0) {
        canvas.drawArc(
          rect,
          start + gapAngle / 2,
          drawn,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..color = colors[i],
        );
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => !listEquals(old.values, values) || !listEquals(old.colors, colors);
}

// ---------------------------------------------------------------- budget hint, need split

class _BudgetHint extends StatelessWidget {
  const _BudgetHint(this.budgets, {required this.onTap});

  final List<BudgetView> budgets;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    double used(BudgetView b) {
      final limit = b.row['amount'] as int;
      return limit == 0 ? 0 : b.spent / limit;
    }

    // The budget closest to its limit is the one worth a glance.
    final b = budgets.reduce((a, b) => used(b) > used(a) ? b : a);
    final limit = b.row['amount'] as int;
    final (_, end) = periodRange(b.row['period'] as String, DateTime.now());
    final now = DateTime.now();
    final daysLeft = DateTime(end.year, end.month, end.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    final detail = b.spent > limit
        ? 'Lewat ${formatAmount(b.spent - limit)} dari batas'
        : 'Sisa ${formatAmount(limit - b.spent)} untuk $daysLeft hari ke depan';
    return Material(
      color: c.primarySoft,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle),
                child: Icon(Icons.eco_outlined, size: 22, color: c.primary),
              ),
              const SizedBox(width: AppSpace.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${b.row['name']} sudah ${percentOf(b.spent, limit)}', style: AppText.bodyStrong),
                    const SizedBox(height: 2),
                    Text(detail, style: AppText.caption.copyWith(color: c.onPrimarySoft)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: c.ink),
            ],
          ),
        ),
      ),
    );
  }
}

/// Segmented bar (14px, 3px gaps) above a list that carries every figure.
class _NeedSplit extends StatelessWidget {
  const _NeedSplit(this.r);

  final MonthReport r;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final colors = c.needLevels;
    final parts = [
      for (final level in const ['must', 'need', 'want', null])
        if ((r.byNeedLevel[level] ?? 0) > 0) (level, r.byNeedLevel[level]!),
    ];
    return _Card(
      children: [
        Text('Wajib, butuh, atau ingin', style: AppText.heading.copyWith(fontSize: 16)),
        const SizedBox(height: 14),
        ExcludeSemantics(
          // The list below says the same in words.
          child: SizedBox(
            height: 14,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, p) in parts.indexed) ...[
                  if (i > 0) const SizedBox(width: 3),
                  Expanded(
                    flex: (p.$2 * 1000 / r.expense).round().clamp(1, 1000),
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: colors[p.$1], borderRadius: BorderRadius.circular(7)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        for (final p in parts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: colors[p.$1], shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Expanded(child: Text(needLevelLabels[p.$1]!, style: AppText.label)),
                Text(formatAmount(p.$2), style: AppText.label.copyWith(color: c.inkMuted)),
                SizedBox(
                  width: 44,
                  child: Text(
                    percentOf(p.$2, r.expense),
                    textAlign: TextAlign.end,
                    style: AppText.label.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- trend

/// Six months of one series. The chosen month is the dark bar with its value; tapping another
/// month opens it.
class _Trend extends StatelessWidget {
  const _Trend({required this.title, required this.totals, required this.end, required this.selected, required this.onSelect});

  final String title;
  final List<int> totals; // oldest first, ending at [end]
  final DateTime end;
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    const plot = 150.0;
    final ticks = niceTicks(totals.fold<int>(0, math.max));
    final top = ticks.last == 0 ? 1 : ticks.last;
    final months = [for (var i = 0; i < totals.length; i++) DateTime(end.year, end.month - (totals.length - 1 - i))];
    final now = DateTime.now();
    final running = selected.year == now.year && selected.month == now.month;
    if (ticks.length == 1) {
      // Six empty months: a flat row of stubs says less than one line of text.
      return _Card(
        children: [
          Text(title, style: AppText.heading.copyWith(fontSize: 16)),
          const SizedBox(height: 8),
          Text('Belum ada data dalam $_trendMonths bulan terakhir.', style: AppText.label.copyWith(color: c.inkMuted)),
        ],
      );
    }
    return _Card(
      children: [
        Text(title, style: AppText.heading.copyWith(fontSize: 16)),
        const SizedBox(height: 28), // room for the value chip above the tallest bar
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                height: plot,
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.outline))),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final (i, m) in months.indexed)
                      Expanded(
                        child: Semantics(
                          button: true,
                          selected: m == selected,
                          label: '${DateFormat('MMMM yyyy', 'id_ID').format(m)}: ${formatAmount(totals[i])}',
                          excludeSemantics: true,
                          onTap: () => onSelect(m), // excludeSemantics drops the InkWell's own action
                          child: InkWell(
                            onTap: () => onSelect(m),
                            child: _Bar(
                              height: plot * totals[i] / top,
                              color: m == selected ? c.primary : c.chartMuted,
                              chip: m == selected ? 'Rp ${_compact.format(totals[i] / 100)}' : null,
                              chipAtEnd: i == months.length - 1, // keeps it clear of the axis labels
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: plot,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final t in ticks.reversed)
                    Text(t == 0 ? '0' : _compact.format(t / 100), style: AppText.caption.copyWith(fontSize: 10, color: c.inkMuted)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final m in months)
              Expanded(
                child: Text(
                  DateFormat('MMM', 'id_ID').format(m),
                  textAlign: TextAlign.center,
                  style: AppText.caption.copyWith(
                    color: m == selected ? c.ink : c.inkMuted,
                    fontWeight: m == selected ? FontWeight.w600 : null,
                  ),
                ),
              ),
            const SizedBox(width: 30), // under the axis labels
          ],
        ),
        if (running) ...[
          const SizedBox(height: 12),
          Text(
            '${DateFormat('MMMM', 'id_ID').format(selected)} masih berjalan, angkanya akan bertambah.',
            style: AppText.caption.copyWith(color: c.inkMuted),
          ),
        ],
      ],
    );
  }
}

/// One column: a bar at most 24px wide, 4px rounded at the top, square at the baseline.
class _Bar extends StatelessWidget {
  const _Bar({required this.height, required this.color, this.chip, this.chipAtEnd = false});

  final double height;
  final Color color;
  final String? chip; // value shown above the chosen bar
  final bool chipAtEnd; // right-align the chip to the column instead of centering it

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox(
      height: 150,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomCenter,
        children: [
          Container(
            width: 24,
            height: math.max(height, 2), // a zero month still shows where it sits
            decoration: BoxDecoration(color: color, borderRadius: const BorderRadius.vertical(top: Radius.circular(4))),
          ),
          if (chip != null)
            Positioned(
              bottom: math.max(height, 2) + 8,
              right: chipAtEnd ? 0 : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: c.primary, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  chip!,
                  maxLines: 1,
                  softWrap: false,
                  style: AppText.caption.copyWith(fontSize: 11, fontWeight: FontWeight.w600, color: c.onPrimary),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
