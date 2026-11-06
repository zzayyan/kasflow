import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    final picked = await chooseOne(context, 'Pilih bulan', [
      for (final m in months) (m, DateFormat('MMMM yyyy', 'id_ID').format(m), null),
    ], _month);
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
                child: Text('Laporan $monthName', style: AppText.title),
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
                Expanded(child: _Kpi('Masuk', r.income, color: c.income)),
                const SizedBox(width: 10),
                Expanded(child: _Kpi('Keluar', r.expense)),
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
              month: _month,
              type: income ? 'income' : 'expense',
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
            child: CountUp(
              amount,
              builder: (v) => Text(formatAmount(v), style: AppText.amount.copyWith(fontSize: 18, color: color ?? c.ink)),
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

class _CategoryCard extends StatefulWidget {
  const _CategoryCard({
    required this.categories,
    required this.total,
    required this.caption,
    required this.chartLabel,
    required this.emptyText,
    required this.labels,
    required this.labelId,
    required this.onLabel,
    required this.month,
    required this.type,
  });

  final List<CategoryTotal> categories; // largest first
  final int total;
  final String caption;
  final String chartLabel;
  final String emptyText;
  final List<Map<String, dynamic>> labels;
  final String? labelId;
  final ValueChanged<String?> onLabel;
  final DateTime month;
  final String type; // 'expense' | 'income'

  @override
  State<_CategoryCard> createState() => _CategoryCardState();
}

const _ringStroke = 24.0;

class _CategoryCardState extends State<_CategoryCard> {
  int? _picked; // the part shown in the middle of the ring; null shows the total

  @override
  void didUpdateWidget(_CategoryCard old) {
    super.didUpdateWidget(old);
    // Another month, view or label has other parts, so the pick would point at the wrong one.
    if (old.type != widget.type || old.month != widget.month || old.labelId != widget.labelId) _picked = null;
  }

  void _pick(int i) {
    HapticFeedback.selectionClick();
    setState(() => _picked = i == _picked ? null : i);
  }

  /// The categories inside part [i]: itself, or every folded one for the gray "Lainnya".
  List<CategoryTotal> _members(List<CategoryTotal> parts, int i) =>
      parts.length != widget.categories.length && i == parts.length - 1 ? widget.categories.sublist(i) : [parts[i]];

  /// A tap on the ring picks its part; a tap in the hole, once a part is picked, lists its records.
  void _tapRing(Offset at, List<CategoryTotal> parts) {
    const size = 200.0;
    final d = at - const Offset(size / 2, size / 2);
    final radius = size / 2 - 6 - _ringStroke / 2;
    final r = d.distance;
    if (r < radius - _ringStroke / 2 - 4) {
      if (_picked case final i?) _showRecords(parts, i);
      return;
    }
    if (r > radius + _ringStroke / 2 + 8) return;
    var angle = math.atan2(d.dy, d.dx) + math.pi / 2; // clockwise from 12 o'clock
    if (angle < 0) angle += 2 * math.pi;
    final total = parts.fold<int>(0, (sum, p) => sum + p.amount);
    var end = 0.0;
    for (final (i, p) in parts.indexed) {
      end += p.amount / total * 2 * math.pi;
      if (angle < end) return _pick(i);
    }
  }

  Future<void> _showRecords(List<CategoryTotal> parts, int i) async {
    final members = _members(parts, i);
    final (start, end) = periodRange('month', widget.month);
    final rows = await db.getAll(
      '''
      SELECT r.amount, r.note, r.occurred_at, a.name AS account, c.name AS category
      FROM records r
      JOIN accounts a ON a.id = r.account_id
      LEFT JOIN categories c ON c.id = r.category_id
      WHERE r.status = 'confirmed' AND a.exclude_from_stats = 0 AND r.type = ?1
        AND julianday(r.occurred_at) >= julianday(?2) AND julianday(r.occurred_at) < julianday(?3)
        AND (?4 IS NULL OR EXISTS (SELECT 1 FROM json_each(r.label_ids) l WHERE l.value = ?4))
        AND (r.category_id IN (SELECT value FROM json_each(?5)) OR (?6 = 1 AND r.category_id IS NULL))
      ORDER BY julianday(r.occurred_at) DESC''',
      [
        widget.type,
        utcIso(start),
        utcIso(end),
        widget.labelId,
        jsonEncode([for (final m in members) ?m.id]),
        members.any((m) => m.id == null) ? 1 : 0,
      ],
    );
    if (!mounted) return;
    final amount = parts[i].amount;
    await showRecordsSheet(
      context,
      title: '${parts[i].name} · ${DateFormat('MMMM', 'id_ID').format(widget.month)}',
      summary: '${rows.length} transaksi · ${formatAmount(amount)} · ${percentOf(amount, widget.total)} dari total',
      rows: rows,
      emptyText: 'Tidak ada transaksi.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // Five hues and a gray for the rest. ponytail: colors follow rank within this month, so a
    // category can change color between months; stable colors need a slot per category.
    final parts = foldSmallest(widget.categories, c.chart.length);
    // Past the five hues (the folded rest, or a sixth part left unfolded) comes the gray.
    final colors = [for (var i = 0; i < parts.length; i++) i < c.chart.length ? c.chart[i] : c.chartOther];
    final picked = _picked != null && _picked! < parts.length ? _picked : null;
    final half = (parts.length / 2).ceil();
    final labelName = widget.labels.where((l) => l['id'] == widget.labelId).firstOrNull?['name'];
    final fade = motion(context, const Duration(milliseconds: 180));

    Widget legend(int i) {
      final p = parts[i];
      return Semantics(
        button: true,
        selected: picked == i,
        label: '${p.name}, ${formatAmount(p.amount)}, ${percentOf(p.amount, widget.total)}',
        excludeSemantics: true,
        onTap: () => _pick(i),
        child: AnimatedOpacity(
          duration: fade,
          opacity: picked == null || picked == i ? 1 : 0.4,
          child: InkWell(
            onTap: () => _pick(i),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: colors[i], shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      p.name,
                      style: AppText.label.copyWith(fontWeight: picked == i ? FontWeight.w600 : null),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(percentOf(p.amount, widget.total), style: AppText.label.copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // The middle of the ring: the total, or the picked part with its change from last month.
    Widget middle() {
      if (picked == null) {
        return Column(
          key: const ValueKey('total'),
          mainAxisSize: MainAxisSize.min,
          children: [
            CountUp(
              widget.total,
              builder: (v) => Text(
                'Rp ${_compact.format(v / 100)}',
                style: AppText.title.copyWith(fontSize: 22, letterSpacing: -0.3),
              ),
            ),
            const SizedBox(height: 2),
            Text(widget.caption, style: AppText.caption.copyWith(color: c.inkMuted)),
          ],
        );
      }
      final p = parts[picked];
      final previous = _members(parts, picked).fold<int>(0, (sum, m) => sum + m.previous);
      final change = previous == 0 ? null : (p.amount - previous) * 100 / previous;
      // More spending is bad news, more income good news.
      final good = change != null && (widget.type == 'expense' ? change <= 0 : change >= 0);
      final lastMonth = DateFormat('MMM', 'id_ID').format(DateTime(widget.month.year, widget.month.month - 1));
      return SizedBox(
        key: ValueKey(picked),
        width: 132,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              p.name,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: c.inkMuted),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(formatAmount(p.amount), style: AppText.title.copyWith(fontSize: 18, letterSpacing: -0.3)),
            ),
            if (change != null)
              Text(
                change.round() == 0
                    ? 'Sama dengan $lastMonth'
                    : '${change > 0 ? '+' : '−'}${change.abs().round()}% dari $lastMonth',
                style: AppText.caption.copyWith(
                  fontWeight: FontWeight.w600,
                  color: good ? VizColors.of(context).good : c.alert,
                ),
              ),
            const SizedBox(height: 4),
            Text(
              'Lihat transaksi',
              style: AppText.caption.copyWith(fontWeight: FontWeight.w600, color: c.primary),
            ),
          ],
        ),
      );
    }

    return _Card(
      children: [
        Row(
          children: [
            Expanded(child: Text('Per kategori', style: AppText.heading.copyWith(fontSize: 16))),
            if (widget.labels.isNotEmpty)
              PopupMenuButton<String>(
                tooltip: 'Saring dengan label',
                initialValue: widget.labelId ?? _allLabels,
                onSelected: (id) => widget.onLabel(id == _allLabels ? null : id),
                itemBuilder: (context) => [
                  const PopupMenuItem(value: _allLabels, child: Text('Semua label')),
                  for (final l in widget.labels) PopupMenuItem(value: l['id'] as String, child: Text('#${l['name']}')),
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
              '${widget.emptyText}.',
              textAlign: TextAlign.center,
              style: AppText.label.copyWith(color: c.inkMuted),
            ),
          )
        else ...[
          Center(
            child: Semantics(
              // The legend rows below are the accessible way to pick a part.
              label: '${widget.chartLabel}, total ${formatAmount(widget.total)}',
              excludeSemantics: true,
              child: GestureDetector(
                onTapUp: (d) => _tapRing(d.localPosition, parts),
                child: SizedBox.square(
                  dimension: 200,
                  // The ring sweeps in clockwise whenever its numbers change (another month or view).
                  child: TweenAnimationBuilder<double>(
                    key: ValueKey(Object.hashAll([for (final p in parts) p.amount])),
                    tween: Tween(begin: 0, end: 1),
                    duration: motion(context, const Duration(milliseconds: 650)),
                    curve: Curves.easeOutCubic,
                    builder: (context, t, child) => CustomPaint(
                      painter: _DonutPainter([for (final p in parts) p.amount], colors, t, picked),
                      child: child,
                    ),
                    child: Center(child: AnimatedSwitcher(duration: fade, child: middle())),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            picked == null ? 'Ketuk warna untuk melihat rinciannya' : 'Ketuk tengah lingkaran untuk daftar transaksinya',
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(color: c.inkMuted),
          ),
          const SizedBox(height: 12),
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
/// [progress] (0 to 1) draws only that share of the circle, for the sweep-in. With [picked], that
/// part is drawn thicker and the others faded.
class _DonutPainter extends CustomPainter {
  const _DonutPainter(this.values, this.colors, [this.progress = 1, this.picked]);

  final List<int> values;
  final List<Color> colors;
  final double progress;
  final int? picked;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2 - 6 - _ringStroke / 2;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: radius);
    final total = values.fold<int>(0, (sum, v) => sum + v);
    if (total <= 0) return;
    final gapAngle = values.length > 1 ? 2 / radius : 0.0; // 2px of arc
    var start = -math.pi / 2;
    final end = start + progress * 2 * math.pi;
    for (final (i, v) in values.indexed) {
      final sweep = v / total * 2 * math.pi;
      if (start >= end) break;
      final drawn = math.min(sweep, end - start) - gapAngle;
      if (drawn > 0) {
        canvas.drawArc(
          rect,
          start + gapAngle / 2,
          drawn,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = picked == i ? _ringStroke + 8 : _ringStroke
            ..color = picked == null || picked == i ? colors[i] : colors[i].withValues(alpha: 0.3),
        );
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.progress != progress ||
      old.picked != picked ||
      !listEquals(old.values, values) ||
      !listEquals(old.colors, colors);
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
        SelectableBars(
          values: totals,
          labels: [for (final m in months) DateFormat('MMM', 'id_ID').format(m)],
          readouts: [
            for (final (i, m) in months.indexed) '${DateFormat('MMMM yyyy', 'id_ID').format(m)}: ${formatAmount(totals[i])}',
          ],
          selected: months.indexOf(selected),
          onSelect: (i) => onSelect(months[i]),
          valueText: (v) => 'Rp ${_compact.format(v / 100)}',
          ticks: ticks,
          tickText: (t) => t == 0 ? '0' : _compact.format(t / 100),
          height: plot,
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
