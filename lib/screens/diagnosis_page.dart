import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';

import '../db.dart';
import '../diagnosis.dart';
import '../money.dart';
import '../reports.dart';
import '../theme.dart';
import '../ui.dart';
import 'accounts_tab.dart';
import 'categories_page.dart';
import 'plans_tab.dart' show budgetSpentSql;

// Diagnosis CFO: the last full month scored on eight pillars (lib/diagnosis.dart), worded by
// Gemini through the diagnose-finance Edge Function. The pillars never wait for the AI.

final _log = Logger('diagnosis');

/// Everything the screen and the Laporan card show for one scored month.
class DiagnosisView {
  const DiagnosisView({
    required this.month,
    required this.scored,
    required this.before,
    required this.netWorth,
    required this.budgetCount,
    required this.payload,
  });

  final DateTime month; // the scored month: the last full one
  final Diagnosis scored;
  final Diagnosis? before; // the month before, for each pillar's change; null when it wasn't recorded
  final List<(DateTime, int)> netWorth; // month ends since recording began, up to six, ending with [month]
  final int budgetCount;
  final String payload; // diagnosisPayload as JSON: what Gemini reads, and the staleness check

  Pillar? previous(PillarKind kind) => before?.pillars.where((p) => p.kind == kind).firstOrNull;
}

/// The last full month's diagnosis, or only the first record's time when there is too little
/// data to score it yet.
Future<({DiagnosisView? view, DateTime? firstRecord})> loadDiagnosis() async {
  final today = DateTime.now();
  final month = DateTime(today.year, today.month - 1);
  final first = await db.getOptional(
    "SELECT occurred_at FROM records WHERE status = 'confirmed' ORDER BY julianday(occurred_at) LIMIT 1",
  );
  final firstRecord = first == null ? null : DateTime.parse(first['occurred_at'] as String).toLocal();
  // ponytail: a month whose first week has records counts as fully recorded.
  bool recorded(DateTime m) => firstRecord != null && firstRecord.isBefore(DateTime(m.year, m.month, 8));
  if (!recorded(month)) {
    return (view: null, firstRecord: firstRecord);
  }

  final end = DateTime(today.year, today.month);
  final accounts = [
    for (final a in await db.getAll(
      'SELECT id, type, initial_balance, exclude_from_stats FROM accounts WHERE COALESCE(archived, 0) = 0',
    ))
      DiagAccount(
        id: a['id'] as String,
        type: a['type'] as String? ?? 'cash',
        initialBalance: a['initial_balance'] as int? ?? 0,
        excluded: a['exclude_from_stats'] != 0, // null counts as excluded, as in the SQL elsewhere
      ),
  ];
  final records = [
    for (final r in await db.getAll(
      '''
      SELECT r.account_id, r.type, r.amount, r.occurred_at, r.transfer_account_id, r.transfer_amount, c.need_level
      FROM records r LEFT JOIN categories c ON c.id = r.category_id
      WHERE r.status = 'confirmed' AND julianday(r.occurred_at) < julianday(?1)''',
      [utcIso(end)],
    ))
      DiagRecord(
        accountId: r['account_id'] as String,
        type: r['type'] as String,
        amount: r['amount'] as int,
        occurredAt: DateTime.parse(r['occurred_at'] as String).toLocal(),
        needLevel: r['need_level'] as String?,
        transferAccountId: r['transfer_account_id'] as String?,
        transferAmount: r['transfer_amount'] as int?,
      ),
  ];
  final bills = [
    for (final b in await db.getAll('''
      SELECT p.type, p.amount, p.rrule FROM planned_payments p LEFT JOIN accounts a ON a.id = p.account_id
      WHERE a.id IS NULL OR (COALESCE(a.archived, 0) = 0 AND a.exclude_from_stats = 0)'''))
      DiagBill(
        type: b['type'] as String? ?? 'expense',
        amount: b['amount'] as int? ?? 0,
        rule: b['rrule'] as String? ?? '',
      ),
  ];
  final goals = [
    for (final g in await db.getAll(
      "SELECT name, account_id, target_amount, target_date FROM goals WHERE state = 'active' AND account_id IS NOT NULL",
    ))
      DiagGoal(
        name: g['name'] as String? ?? 'Target',
        accountId: g['account_id'] as String,
        target: g['target_amount'] as int? ?? 0,
        targetDate: g['target_date'] == null ? null : DateTime.parse(g['target_date'] as String),
      ),
  ];
  final budgetRows = await db.getAll('SELECT * FROM budgets');

  Diagnosis score(DateTime m, List<DiagBudget> budgets) =>
      diagnose(month: m, accounts: accounts, records: records, bills: bills, budgets: budgets, goals: goals);

  final budgets = await _budgetsFor(budgetRows, month);
  final scored = score(month, budgets);
  final previous = DateTime(month.year, month.month - 1);
  final before = recorded(previous) ? score(previous, await _budgetsFor(budgetRows, previous)) : null;
  // From the first recorded month on: earlier month ends are only opening balances.
  final netWorth = [
    for (var i = 5; i >= 0; i--)
      if (DateTime(month.year, month.month - i) case final m
          when !m.isBefore(DateTime(firstRecord!.year, firstRecord.month)))
        (m, score(m, const []).pillars.firstWhere((p) => p.kind == PillarKind.netWorth).value!.round()),
  ];

  final categories = [
    for (final c in await db.getAll(
      '''
      SELECT c.name, c.need_level,
        SUM(CASE WHEN julianday(r.occurred_at) >= julianday(?2) THEN r.amount ELSE 0 END) AS cur,
        SUM(CASE WHEN julianday(r.occurred_at) < julianday(?2) THEN r.amount ELSE 0 END) AS prev
      FROM records r
      JOIN accounts a ON a.id = r.account_id
      LEFT JOIN categories c ON c.id = r.category_id
      WHERE r.status = 'confirmed' AND a.exclude_from_stats = 0 AND COALESCE(a.archived, 0) = 0
        AND r.type = 'expense'
        AND julianday(r.occurred_at) >= julianday(?1) AND julianday(r.occurred_at) < julianday(?3)
      GROUP BY r.category_id
      ORDER BY cur DESC
      LIMIT 12''',
      [utcIso(DateTime(month.year, month.month - 1)), utcIso(month), utcIso(end)],
    ))
      CategoryAmount(
        c['name'] as String? ?? 'Tanpa kategori',
        c['need_level'] as String?,
        c['cur'] as int,
        c['prev'] as int,
      ),
  ];

  return (
    view: DiagnosisView(
      month: month,
      scored: scored,
      before: before,
      netWorth: netWorth,
      budgetCount: budgets.length,
      payload: jsonEncode(diagnosisPayload(scored, categories: categories)),
    ),
    firstRecord: firstRecord,
  );
}

/// Each budget period that ended in [month], with what it spent. A yearly budget still running is
/// judged by its pace: its limit scaled by how much of the year has passed at the month's end.
Future<List<DiagBudget>> _budgetsFor(List<Map<String, dynamic>> rows, DateTime month) async {
  final monthEnd = DateTime(month.year, month.month + 1);
  final out = <DiagBudget>[];
  for (final b in rows) {
    final started = b['start_date'] == null ? null : DateTime.parse(b['start_date'] as String);
    if (started != null && !started.isBefore(monthEnd)) continue; // made after the month
    final limit = b['amount'] as int? ?? 0;
    final periods = <(DateTime, DateTime, int)>[];
    switch (b['period']) {
      case 'month':
        periods.add((month, monthEnd, limit));
      case 'week':
        // The weeks whose last day falls in the month.
        var (start, end) = periodRange('week', month);
        while (!end.isAfter(monthEnd)) {
          if (end.isAfter(month)) periods.add((start, end, limit));
          (start, end) = periodRange('week', end);
        }
      case 'year':
        final (start, end) = periodRange('year', month);
        final share = monthEnd.difference(start).inHours / end.difference(start).inHours;
        periods.add((start, monthEnd, (limit * share).round()));
    }
    for (final (from, to, cap) in periods) {
      if (started != null && to.isBefore(started)) continue;
      final spent =
          (await db.get(budgetSpentSql, [
                utcIso(from),
                utcIso(to),
                b['category_ids'] ?? '[]',
                b['account_ids'] ?? '[]',
                b['label_ids'] ?? '[]',
              ]))['spent']
              as int;
      out.add(DiagBudget(spent: spent, limit: cap));
    }
  }
  return out;
}

// ---------------------------------------------------------------- AI advice, cached per month

class Advice {
  const Advice(this.summary, this.steps, this.madeAt);
  final String summary;
  final List<(String, String)> steps; // title, why
  final DateTime madeAt;
}

const _adviceKey = 'diagnosis_advice'; // {payload, advice, at} as JSON, on this phone only

Advice? _parseAdvice(Object? a, DateTime madeAt) {
  if (a is! Map || a['summary'] is! String || a['steps'] is! List) return null;
  final steps = [
    for (final s in (a['steps'] as List).take(3))
      if (s is Map && s['title'] is String && s['why'] is String) (s['title'] as String, s['why'] as String),
  ];
  return steps.isEmpty ? null : Advice(a['summary'] as String, steps, madeAt);
}

/// The stored advice and the payload it was made from, when it was made for [view]'s month.
Future<({Advice advice, bool stale})?> cachedAdvice(DiagnosisView view) async {
  final raw = await getPref(_adviceKey);
  if (raw == null) return null;
  try {
    final stored = jsonDecode(raw) as Map<String, dynamic>;
    final payload = stored['payload'] as String;
    if (jsonDecode(payload)['month'] != jsonDecode(view.payload)['month']) return null;
    final advice = _parseAdvice(stored['advice'], DateTime.parse(stored['at'] as String).toLocal());
    return advice == null ? null : (advice: advice, stale: payload != view.payload);
  } on Object catch (e) {
    _log.warning('Stored diagnosis advice unreadable', e);
    return null;
  }
}

/// Asks Gemini for new advice on [view] and stores it. Null when offline, over quota or failing.
Future<Advice?> fetchAdvice(DiagnosisView view) async {
  try {
    final response = await supabase.functions
        .invoke('diagnose-finance', body: jsonDecode(view.payload))
        .timeout(const Duration(seconds: 60));
    final at = DateTime.now();
    final advice = _parseAdvice(response.data, at);
    if (advice == null) return null;
    await setPref(
      _adviceKey,
      jsonEncode({'payload': view.payload, 'advice': response.data, 'at': at.toUtc().toIso8601String()}),
    );
    return advice;
  } on Exception catch (e) {
    _log.warning('Diagnosis advice unavailable', e);
    return null;
  }
}

// ---------------------------------------------------------------- wording

const _names = {
  PillarKind.emergency: 'Dana darurat',
  PillarKind.savings: 'Tingkat tabungan',
  PillarKind.spending: 'Pola belanja',
  PillarKind.fixedCosts: 'Beban tetap',
  PillarKind.goals: 'Laju target',
  PillarKind.debt: 'Beban utang',
  PillarKind.budgets: 'Disiplin anggaran',
  PillarKind.netWorth: 'Kekayaan bersih',
};

final _oneDecimal = NumberFormat('#,##0.0', 'id_ID');
String _pct(double v) => '${(v * 100).round()}%';
String _monthName(DateTime m) => DateFormat('MMMM', 'id_ID').format(m);

/// "31 Okt": the month end balances are taken at, so they never read as today's balance.
String _monthEnd(DateTime m) => DateFormat('d MMM', 'id_ID').format(DateTime(m.year, m.month + 1, 0));

/// The headline figure: "1,4 bulan", "18%", "Rp 48,6 jt", "1 jebol".
String _headline(Pillar p) {
  final v = p.value;
  if (v == null) return '–';
  return switch (p.kind) {
    PillarKind.emergency => '${_oneDecimal.format(v)} bulan',
    PillarKind.netWorth => formatCompact(v.round()),
    PillarKind.budgets => '${v.round()} jebol',
    PillarKind.goals => '${v.round()} tertinggal',
    _ => _pct(v),
  };
}

/// One line under the pillar's name.
String _valueLine(Pillar p, DiagnosisView view) {
  final v = p.value;
  if (v == null || (p.kind == PillarKind.debt && p.reason != null)) return p.reason ?? '–';
  final goals = view.scored.goals.length;
  return switch (p.kind) {
    PillarKind.emergency => '${_oneDecimal.format(v)} bulan pengeluaran wajib dan butuh',
    PillarKind.savings => '${_pct(v)} dari pemasukan, rata-rata 3 bulan',
    PillarKind.spending => 'Ingin ${_pct(v)} dari pengeluaran',
    PillarKind.fixedCosts => p.amounts.isEmpty ? 'Belum ada tagihan rutin' : 'Tagihan rutin ${_pct(v)} dari pemasukan',
    PillarKind.debt => p.amounts.isEmpty ? 'Tidak ada utang' : 'Cicilan ${_pct(v)} dari pemasukan',
    PillarKind.budgets =>
      v == 0
          ? '${view.budgetCount} anggaran, tidak ada yang jebol'
          : '${v.round()} dari ${view.budgetCount} anggaran jebol',
    PillarKind.goals =>
      goals == 0
          ? 'Semua target bertanggal tercapai'
          : v == 0
          ? 'Semua $goals target sesuai jadwal'
          : '${v.round()} dari $goals target tertinggal',
    PillarKind.netWorth => '${formatCompact(v.round())} per ${_monthEnd(view.month)}',
  };
}

/// The value line without the headline it starts with: "5,5 bulan" once, not twice.
String _underHeadline(Pillar p, DiagnosisView view) {
  final line = _valueLine(p, view), head = _headline(p);
  return line.startsWith(head) ? line.substring(head.length).trim() : line;
}

/// The change from the month before, with its direction (-1, 0, 1). Null when either is unmeasured.
(String, int)? _delta(Pillar p, Pillar? before, DateTime month) {
  final now = p.value, then = before?.value;
  if (now == null || then == null) return null;
  String move(int dir, String amount) => dir == 0 ? 'Sama' : '${dir > 0 ? 'Naik' : 'Turun'} $amount';
  switch (p.kind) {
    case PillarKind.emergency:
      final diff = ((now - then) * 10).round();
      return (move(diff.sign, '${_oneDecimal.format(diff.abs() / 10)} bulan'), diff.sign);
    case PillarKind.netWorth:
      final diff = (now - then).round();
      return (move(diff.sign, formatCompact(diff.abs())), diff.sign);
    case PillarKind.budgets || PillarKind.goals:
      final diff = (now - then).round();
      final word = p.kind == PillarKind.budgets ? 'jebol' : 'tertinggal';
      return (
        diff == 0 ? 'Sama' : '${_monthName(DateTime(month.year, month.month - 1))} ${then.round()} $word',
        diff.sign,
      );
    default:
      final diff = ((now - then) * 100).round();
      return (move(diff.sign, '${diff.abs()} poin'), diff.sign);
  }
}

/// Steps from fixed rules, Bahaya pillars first, then Waspada, at most three: what shows when
/// Gemini can't answer. Each aims at the next band up.
List<(String, String)> _ruleSteps(DiagnosisView view) => [
  for (final health in const [Health.bad, Health.warn])
    for (final p in view.scored.pillars)
      if (p.health == health) ?_ruleStep(p, view, bad: health == Health.bad),
].take(3).toList();

(String, String)? _ruleStep(Pillar p, DiagnosisView view, {required bool bad}) {
  if (p.value == null && p.reason == noIncome) {
    return (
      'Catat pemasukanmu',
      'Tidak ada pemasukan tercatat dalam 3 bulan terakhir, jadi pilar ini tidak bisa dinilai.',
    );
  }
  final line = _valueLine(p, view);
  return switch (p.kind) {
    PillarKind.emergency => (
      'Bangun dana darurat sampai ${bad ? 3 : 6} bulan',
      'Saat ini $line. Patokan ${bad ? 'minimal 3' : 'aman 6'} bulan.',
    ),
    PillarKind.savings => ('Sisihkan minimal ${bad ? 10 : 20}% pemasukan', 'Tingkat tabunganmu $line.'),
    PillarKind.spending => ('Tekan belanja Ingin ke ${bad ? 'di bawah 40' : 'paling banyak 30'}%', 'Saat ini $line.'),
    PillarKind.fixedCosts => ('Tinjau tagihan rutin', '$line, ${bad ? 'lewat batas 50' : 'di atas patokan 30'}%.'),
    PillarKind.debt when p.reason != null => ('Lunasi tagihan kartu kredit', '$line.'),
    PillarKind.debt => ('Turunkan cicilan di bawah ${bad ? 40 : 30}% pemasukan', '$line.'),
    PillarKind.budgets => ('Sesuaikan anggaran yang jebol', '$line.'),
    PillarKind.goals => ('Tinjau target yang tertinggal', '$line. Tambah setoran atau mundurkan tenggatnya.'),
    PillarKind.netWorth when bad => ('Hentikan kekayaan bersih yang minus', 'Utangmu lebih besar dari asetmu: $line.'),
    PillarKind.netWorth => (
      'Cari penyebab kekayaan bersih turun',
      'Kekayaan bersih $line, lebih rendah dari 3 bulan lalu.',
    ),
  };
}

/// "3 sehat · 4 waspada · 1 bahaya", leaving out empty groups. Unscored pillars show in the list.
String _countLine(Diagnosis d) => [
  if (d.count(Health.good) > 0) '${d.count(Health.good)} sehat',
  if (d.count(Health.warn) > 0) '${d.count(Health.warn)} waspada',
  if (d.count(Health.bad) > 0) '${d.count(Health.bad)} bahaya',
].join(' · ');

// ---------------------------------------------------------------- the screen

class DiagnosisPage extends StatefulWidget {
  const DiagnosisPage({super.key});

  @override
  State<DiagnosisPage> createState() => _DiagnosisPageState();
}

class _DiagnosisPageState extends State<DiagnosisPage> {
  ({DiagnosisView? view, DateTime? firstRecord})? _data;
  Advice? _advice;
  bool _stale = false;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final data = await loadDiagnosis();
    final view = data.view;
    final cached = view == null ? null : await cachedAdvice(view);
    if (!mounted) return;
    setState(() {
      _data = data;
      _advice = cached?.advice;
      _stale = cached?.stale ?? false;
    });
    // A new month gets its narrative the first time the screen opens.
    if (view != null && cached == null) await _ask();
  }

  Future<void> _ask() async {
    final view = _data?.view;
    if (view == null || _asking) return;
    setState(() => _asking = true);
    final advice = await fetchAdvice(view);
    if (!mounted) return;
    setState(() {
      _asking = false;
      if (advice != null) {
        _advice = advice;
        _stale = false;
      }
    });
    if (advice == null) showMessage(context, 'Gagal memperbarui diagnosis. Coba lagi nanti.');
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final data = _data;
    final view = data?.view;
    return Scaffold(
      body: SafeArea(
        child: data == null
            ? const Center(child: CircularProgressIndicator())
            : view == null
            ? _Pending(firstRecord: data.firstRecord)
            : ListView(
                padding: const EdgeInsets.fromLTRB(AppSpace.page, 16, AppSpace.page, 28),
                children: [
                  const _Header(),
                  const SizedBox(height: 16),
                  _Summary(view: view, advice: _advice, asking: _asking, stale: _stale, onAsk: _ask),
                  const SizedBox(height: 16),
                  _Steps(
                    steps: _advice?.steps ?? _ruleSteps(view),
                    caption: _advice != null
                        ? 'Disusun dari pilar Bahaya dan Waspada'
                        : _asking
                        ? 'Menunggu AI. Sementara dari aturan dasar.'
                        : 'Dari aturan dasar, tanpa AI',
                  ),
                  const SizedBox(height: 16),
                  _Pillars(view: view),
                  const SizedBox(height: 16),
                  _NetWorth(view: view),
                  const SizedBox(height: 8),
                  Text(
                    'Bulan ${_monthName(DateTime.now())} dinilai setelah bulannya selesai.',
                    style: AppText.caption.copyWith(color: c.inkMuted),
                  ),
                ],
              ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      children: [
        IconButton(
          tooltip: 'Kembali',
          onPressed: () => Navigator.pop(context),
          style: IconButton.styleFrom(backgroundColor: c.surface, fixedSize: const Size.square(46)),
          icon: Icon(Icons.chevron_left, color: c.ink),
        ),
        Expanded(
          child: Text('Diagnosis CFO', textAlign: TextAlign.center, style: AppText.title.copyWith(fontSize: 20)),
        ),
        const SizedBox(width: 46),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.view,
    required this.advice,
    required this.asking,
    required this.stale,
    required this.onAsk,
  });

  final DiagnosisView view;
  final Advice? advice;
  final bool asking;
  final bool stale;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final d = view.scored;
    final body = AppText.body.copyWith(color: c.onHero, height: 1.5);
    final advice = this.advice;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 14),
      decoration: BoxDecoration(color: c.hero, borderRadius: BorderRadius.circular(AppRadius.hero)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Rapor ${_monthName(view.month)} ${view.month.year}',
            style: AppText.label.copyWith(color: c.onHeroMuted),
          ),
          const SizedBox(height: 4),
          Text(_countLine(d), style: AppText.title.copyWith(fontSize: 22, color: c.onHero)),
          const SizedBox(height: 14),
          // Scored pillars only; the hero is dark green in both modes, so its colors are fixed.
          Row(
            children: [
              for (final (health, color) in [
                (Health.good, c.onHeroChip),
                (Health.warn, AppColors.dark.warn),
                (Health.bad, c.onHeroAlert),
              ])
                if (d.count(health) > 0)
                  Expanded(
                    flex: d.count(health),
                    child: Container(
                      height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
                    ),
                  ),
            ],
          ),
          const SizedBox(height: 14),
          if (advice != null)
            Text(advice.summary, style: body)
          else if (asking)
            Row(
              children: [
                SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: c.onHeroChip)),
                const SizedBox(width: 10),
                Expanded(child: Text('Menyusun ringkasan…', style: body)),
              ],
            )
          else ...[
            Text(
              'Ringkasan AI belum bisa dibuat. Penilaian pilar di bawah tetap dihitung dari catatanmu.',
              style: body,
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: () {
                  haptic(Haptic.tick);
                  onAsk();
                },
                style: FilledButton.styleFrom(
                  backgroundColor: c.heroChip,
                  foregroundColor: c.onHeroChip,
                  minimumSize: const Size(64, 44),
                  textStyle: AppText.bodyStrong.copyWith(fontSize: 14),
                ),
                child: const Text('Coba lagi'),
              ),
            ),
          ],
          if (stale && advice != null && !asking) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
              decoration: BoxDecoration(color: c.heroChip, borderRadius: BorderRadius.circular(AppRadius.input)),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Data ${_monthName(view.month)} berubah sejak diagnosis ini dibuat.',
                      style: AppText.label.copyWith(color: c.onHeroChip),
                    ),
                  ),
                  FilledButton(
                    onPressed: () {
                      haptic(Haptic.tick);
                      onAsk();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: c.onHero,
                      foregroundColor: c.hero,
                      minimumSize: const Size(64, 44),
                      textStyle: AppText.bodyStrong.copyWith(fontSize: 14),
                    ),
                    child: const Text('Perbarui'),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Divider(color: c.heroChip, height: 1),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  advice == null
                      ? 'Ringkasan dan langkah AI muncul setelah koneksi pulih.'
                      : 'Dibuat AI dari catatanmu. Bukan nasihat keuangan profesional.',
                  style: AppText.caption.copyWith(color: c.onHeroMuted),
                ),
              ),
              if (advice != null)
                IconButton(
                  tooltip: 'Perbarui diagnosis',
                  onPressed: asking
                      ? null
                      : () {
                          haptic(Haptic.tick);
                          onAsk();
                        },
                  style: IconButton.styleFrom(backgroundColor: c.heroChip, fixedSize: const Size.square(44)),
                  icon: Icon(Icons.refresh, size: 18, color: c.onHeroChip),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, this.caption, required this.children});

  final String title;
  final String? caption;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: AppText.heading),
          if (caption != null) ...[
            const SizedBox(height: 2),
            Text(caption!, style: AppText.caption.copyWith(color: c.inkMuted)),
          ],
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.steps, required this.caption});

  final List<(String, String)> steps;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return _Card(
      title: 'Langkah bulan ini',
      caption: caption,
      children: [
        if (steps.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('Semua pilar yang dinilai sehat.', style: AppText.body.copyWith(color: c.inkMuted)),
          ),
        for (final (i, (title, why)) in steps.indexed)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              border: i == steps.length - 1 ? null : Border(bottom: BorderSide(color: c.divider)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: c.primarySoft, shape: BoxShape.circle),
                  child: Text('${i + 1}', style: AppText.bodyStrong.copyWith(color: c.primary)),
                ),
                const SizedBox(width: AppSpace.gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: AppText.bodyStrong),
                      const SizedBox(height: 3),
                      Text(why, style: AppText.label.copyWith(color: c.inkMuted, height: 1.4)),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Sehat / Waspada / Bahaya / Belum dinilai, told apart by text and icon as well as color.
class HealthChip extends StatelessWidget {
  const HealthChip(this.health, {super.key, this.text});

  final Health health;
  final String? text; // instead of the status name, e.g. "3 sehat"

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final (label, icon, bg, fg) = switch (health) {
      Health.good => ('Sehat', Icons.check, c.primarySoft, c.primary),
      Health.warn => ('Waspada', Icons.priority_high, c.warnSoft, c.warn),
      Health.bad => ('Bahaya', Icons.warning_amber_rounded, c.alertSoft, c.alert),
      Health.unknown => ('Belum dinilai', Icons.remove, c.surfaceMuted, c.ink),
    };
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 5),
          Text(
            text ?? label,
            style: AppText.caption.copyWith(color: fg, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _Pillars extends StatelessWidget {
  const _Pillars({required this.view});

  final DiagnosisView view;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final pillars = view.scored.pillars;
    return _Card(
      title: 'Kesehatan keuangan',
      caption:
          'Dibanding ${_monthName(DateTime(view.month.year, view.month.month - 1))}. Ketuk untuk melihat cara hitungnya.',
      children: [
        for (final (i, p) in pillars.indexed)
          InkWell(
            onTap: () {
              haptic(Haptic.tick);
              unawaited(_showPillar(context, p, view));
            },
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                border: i == pillars.length - 1 ? null : Border(bottom: BorderSide(color: c.divider)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_names[p.kind]!, style: AppText.bodyStrong),
                        const SizedBox(height: 3),
                        Text(_valueLine(p, view), style: AppText.label),
                        if (_delta(p, view.previous(p.kind), view.month) case (final text, final dir)) ...[
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Icon(
                                dir > 0
                                    ? Icons.arrow_upward
                                    : dir < 0
                                    ? Icons.arrow_downward
                                    : Icons.remove,
                                size: 12,
                                color: c.inkMuted,
                              ),
                              const SizedBox(width: 4),
                              Text(text, style: AppText.caption.copyWith(color: c.inkMuted)),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpace.gap),
                  HealthChip(p.health),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _NetWorth extends StatelessWidget {
  const _NetWorth({required this.view});

  final DiagnosisView view;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final months = [for (final (m, _) in view.netWorth) m];
    final values = [for (final (_, v) in view.netWorth) v];
    // Against three month ends earlier, or the first recorded one when recording is younger.
    final from = values.length > 3 ? values.length - 4 : 0;
    final change = values.last - values[from];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Kekayaan bersih', style: AppText.heading),
                    const SizedBox(height: 2),
                    Text(
                      'Aset dikurangi utang, per ${_monthEnd(view.month)}',
                      style: AppText.caption.copyWith(color: c.inkMuted),
                    ),
                  ],
                ),
              ),
              Text(formatCompact(values.last), style: AppText.amount.copyWith(fontSize: 18)),
            ],
          ),
          const SizedBox(height: 12),
          Semantics(
            label:
                'Kekayaan bersih ${DateFormat('MMMM', 'id_ID').format(months.first)} sampai '
                '${DateFormat('MMMM', 'id_ID').format(months.last)}: ${values.map(formatCompact).join(', ')}',
            child: SizedBox(
              height: 132,
              child: CustomPaint(
                painter: _LinePainter(values, line: c.primary, grid: c.divider, dotFill: c.surface),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final (i, m) in months.indexed)
                Expanded(
                  child: Text(
                    DateFormat('MMM', 'id_ID').format(m),
                    textAlign: TextAlign.center,
                    style: AppText.caption.copyWith(
                      color: i == months.length - 1 ? c.ink : c.inkMuted,
                      fontWeight: i == months.length - 1 ? FontWeight.w600 : null,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (values.length > 1)
            Text(
              '${change == 0
                  ? 'Sama dengan'
                  : change > 0
                  ? 'Naik ${formatCompact(change)} dari'
                  : 'Turun ${formatCompact(-change)} dari'} '
              '${_monthName(months[from])}. Investasi dihitung sesuai saldo yang kamu catat.',
              style: AppText.caption.copyWith(color: c.inkMuted),
            ),
        ],
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.values, {required this.line, required this.grid, required this.dotFill});

  final List<int> values;
  final Color line;
  final Color grid;
  final Color dotFill;

  @override
  void paint(Canvas canvas, Size size) {
    final lo = values.reduce((a, b) => a < b ? a : b), hi = values.reduce((a, b) => a > b ? a : b);
    final span = hi == lo ? 1 : hi - lo;
    const pad = 10.0;
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final y in [pad, size.height / 2, size.height - pad]) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    // Points sit at the centers of six equal columns, matching the month labels below.
    final points = [
      for (final (i, v) in values.indexed)
        Offset(size.width * (i + 0.5) / values.length, size.height - pad - (v - lo) / span * (size.height - 2 * pad)),
    ];
    canvas.drawPath(
      Path()..addPolygon(points, false),
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );
    for (final (i, p) in points.indexed) {
      if (i == points.length - 1) {
        canvas.drawCircle(p, 5, Paint()..color = line);
      } else {
        canvas.drawCircle(p, 3.5, Paint()..color = dotFill);
        canvas.drawCircle(
          p,
          3.5,
          Paint()
            ..color = line
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.values != values || old.line != line;
}

class _Pending extends StatelessWidget {
  const _Pending({required this.firstRecord});

  final DateTime? firstRecord;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final now = DateTime.now();
    final days = DateTime(now.year, now.month + 1, 0).day;
    final first = firstRecord;
    // From the first record when it is in this month, else the whole month so far.
    final recorded = first == null
        ? 0
        : first.year == now.year && first.month == now.month
        ? now.day - first.day + 1
        : now.day;
    // Recording from the first week on makes this month the first one scored.
    final ready = first != null && first.isBefore(DateTime(now.year, now.month, 8))
        ? DateTime(now.year, now.month + 1)
        : DateTime(now.year, now.month + 2);
    return Column(
      children: [
        const Padding(padding: EdgeInsets.fromLTRB(AppSpace.page, 16, AppSpace.page, 0), child: _Header()),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 80),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(color: c.primarySoft, shape: BoxShape.circle),
                  child: Icon(Icons.monitor_heart_outlined, size: 40, color: c.primary),
                ),
                const SizedBox(height: 20),
                Text(
                  'Diagnosis pertama siap ${DateFormat('d MMMM', 'id_ID').format(ready)}',
                  textAlign: TextAlign.center,
                  style: AppText.title.copyWith(fontSize: 20),
                ),
                const SizedBox(height: 10),
                Text(
                  'Diagnosis menilai bulan yang sudah lengkap. Catat pemasukan dan pengeluaranmu sampai akhir '
                  '${_monthName(DateTime(ready.year, ready.month - 1))} supaya hasilnya akurat.',
                  textAlign: TextAlign.center,
                  style: AppText.body.copyWith(height: 1.5),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.tile)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text('${_monthName(now)} tercatat', style: AppText.label)),
                          Text('$recorded dari $days hari', style: AppText.label.copyWith(fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: recorded / days,
                          minHeight: 8,
                          backgroundColor: c.surfaceMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- one pillar, in a sheet

const _formulas = {
  PillarKind.emergency:
      'Saldo siap pakai = kas, bank, e-wallet, dan tabungan. Investasi tidak dihitung. Pengeluaran wajib dan butuh '
      'dirata-rata dari 3 bulan terakhir.',
  PillarKind.savings:
      'Pemasukan dikurangi pengeluaran, dibagi pemasukan, dari 3 bulan terakhir. Akun yang tidak masuk statistik '
      'tidak dihitung.',
  PillarKind.spending: 'Pengeluaran berlevel Ingin dibagi seluruh pengeluaran, dari 3 bulan terakhir.',
  PillarKind.fixedCosts: 'Tagihan rutin di Rencana, dihitung per bulan, dibagi rata-rata pemasukan bulanan.',
  PillarKind.debt:
      'Transfer ke akun pinjaman dibagi pemasukan, dari 3 bulan terakhir. Kartu kredit dinilai waspada kalau '
      'saldonya naik dua bulan berturut-turut.',
  PillarKind.budgets: 'Anggaran yang periodenya berakhir di bulan ini. Anggaran tahunan dinilai dari lajunya.',
  PillarKind.goals:
      'Target bertanggal yang belum tercapai. Tertinggal berarti setoran 3 bulan terakhir kurang dari kebutuhan '
      'per bulan. Bahaya kalau tenggatnya kurang dari 3 bulan.',
  PillarKind.netWorth: 'Saldo semua akun, termasuk investasi dan utang, di akhir bulan, dibanding 3 bulan sebelumnya.',
};

const _amountLabels = {
  'liquid': 'Saldo siap pakai',
  'essentials_per_month': 'Wajib + butuh per bulan',
  'income_per_month': 'Pemasukan per bulan',
  'expense_per_month': 'Pengeluaran per bulan',
  'want_per_month': 'Belanja Ingin per bulan',
  'bills_per_month': 'Tagihan rutin per bulan',
  'installments_per_month': 'Cicilan per bulan',
  'owed': 'Total utang',
  'three_months_ago': 'Tiga bulan lalu',
};

/// Thresholds as (low, high, higher is better), for the pillars measured on a scale.
const _bands = {
  PillarKind.emergency: (3.0, 6.0, true),
  PillarKind.savings: (0.1, 0.2, true),
  PillarKind.spending: (0.3, 0.4, false),
  PillarKind.fixedCosts: (0.3, 0.5, false),
  PillarKind.debt: (0.3, 0.4, false),
};

Future<void> _showPillar(BuildContext context, Pillar p, DiagnosisView view) {
  final c = AppColors.of(context);
  final before = view.previous(p.kind);
  final link = switch (p.kind) {
    _ when p.reason == setLevels => ('Atur kategori', () => const CategoriesPage()),
    PillarKind.spending => ('Atur kategori', () => const CategoriesPage()),
    PillarKind.emergency || PillarKind.debt || PillarKind.netWorth => ('Lihat akun', () => const AccountsPage()),
    _ => null,
  };
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheet) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(_names[p.kind]!, style: AppText.title.copyWith(fontSize: 20))),
              HealthChip(p.health),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
            decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_headline(p), style: AppText.amountLg),
                const SizedBox(height: 4),
                Text(_underHeadline(p, view), style: AppText.body),
                if (_bands[p.kind] case final band? when p.value != null) ...[
                  const SizedBox(height: 14),
                  _BandBar(value: p.value!, band: band, unit: p.kind == PillarKind.emergency ? ' bln' : '%'),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
            child: Column(
              children: [
                for (final e in p.amounts.entries)
                  if (_amountLabels[e.key] case final label?)
                    _Row(switch (e.key) {
                      'liquid' || 'owed' => '$label, ${_monthEnd(view.month)}',
                      'three_months_ago' => _monthEnd(DateTime(view.month.year, view.month.month - 3)),
                      _ => label,
                    }, formatAmount(e.value)),
                _Row(
                  _monthName(DateTime(view.month.year, view.month.month - 1)),
                  before == null ? '–' : _headline(before),
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(_formulas[p.kind]!, style: AppText.caption.copyWith(color: c.inkMuted, height: 1.45)),
          ),
          if (link case (final label, final page)) ...[
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                haptic(Haptic.tick);
                Navigator.pop(sheet);
                unawaited(Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page())));
              },
              child: Text(label),
            ),
          ],
        ],
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.last = false});

  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: c.divider)),
      ),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AppText.label.copyWith(fontSize: 14))),
          Text(value, style: AppText.amount.copyWith(fontSize: 14)),
        ],
      ),
    );
  }
}

/// Three equal segments (Bahaya, Waspada, Sehat in the pillar's direction) and a marker at [value].
class _BandBar extends StatelessWidget {
  const _BandBar({required this.value, required this.band, required this.unit});

  final double value;
  final (double, double, bool) band;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final (low, high, higherBetter) = band;
    // Each segment takes a third; the last one runs as far past [high] as the middle one is wide.
    final at = value < low
        ? value / low / 3
        : value < high
        ? (1 + (value - low) / (high - low)) / 3
        : (2 + ((value - high) / (high - low)).clamp(0.0, 1.0)) / 3;
    String fmt(double v) =>
        unit == '%' ? '${(v * 100).round()}%' : '${_oneDecimal.format(v).replaceAll(',0', '')}$unit';
    final colors = higherBetter ? [c.alertSoft, c.warnSoft, c.primarySoft] : [c.primarySoft, c.warnSoft, c.alertSoft];
    final labels = higherBetter
        ? ['Bahaya, di bawah ${fmt(low)}', 'Waspada', 'Sehat, ${fmt(high)}+']
        : ['Sehat, sampai ${fmt(low)}', 'Waspada', 'Bahaya, di atas ${fmt(high)}'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 20,
          child: LayoutBuilder(
            builder: (context, box) => Stack(
              alignment: Alignment.centerLeft,
              children: [
                Row(
                  children: [
                    for (final (i, color) in colors.indexed) ...[
                      if (i > 0) const SizedBox(width: 3),
                      Expanded(
                        child: Container(
                          height: 12,
                          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
                        ),
                      ),
                    ],
                  ],
                ),
                Positioned(
                  left: (box.maxWidth * at - 2).clamp(0.0, box.maxWidth - 4),
                  child: Container(
                    width: 4,
                    height: 20,
                    decoration: BoxDecoration(color: c.ink, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final (i, text) in labels.indexed)
              Expanded(
                child: Text(
                  text,
                  textAlign: i == 0
                      ? TextAlign.start
                      : i == 1
                      ? TextAlign.center
                      : TextAlign.end,
                  style: AppText.caption.copyWith(color: c.inkMuted),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- the card at the top of Laporan

/// The way into Diagnosis CFO from Laporan: the last full month's statuses and the first step.
class DiagnosisCard extends StatefulWidget {
  const DiagnosisCard({super.key});

  @override
  State<DiagnosisCard> createState() => _DiagnosisCardState();
}

class _DiagnosisCardState extends State<DiagnosisCard> {
  ({DiagnosisView? view, DateTime? firstRecord})? _data;
  String? _firstStep;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final data = await loadDiagnosis();
    final view = data.view;
    final cached = view == null ? null : await cachedAdvice(view);
    final rules = view == null ? const <(String, String)>[] : _ruleSteps(view);
    if (!mounted) return;
    setState(() {
      _data = data;
      _firstStep = cached?.advice.steps.first.$1 ?? rules.firstOrNull?.$1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final data = _data;
    if (data == null) return const SizedBox.shrink();
    final view = data.view;
    final step = _firstStep;
    return Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () async {
          haptic(Haptic.tick);
          await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const DiagnosisPage()));
          await _load(); // the screen may have fetched new advice
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: c.hero, shape: BoxShape.circle),
                    child: Icon(Icons.monitor_heart_outlined, size: 22, color: c.onHero),
                  ),
                  const SizedBox(width: AppSpace.gap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Diagnosis CFO', style: AppText.bodyStrong),
                        const SizedBox(height: 2),
                        Text(
                          view == null
                              ? 'Rapor pertama setelah sebulan penuh tercatat'
                              : 'Rapor ${_monthName(view.month)}',
                          style: AppText.caption.copyWith(color: c.inkMuted),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: c.ink),
                ],
              ),
              if (view != null) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (health, word) in [
                      (Health.good, 'sehat'),
                      (Health.warn, 'waspada'),
                      (Health.bad, 'bahaya'),
                    ])
                      if (view.scored.count(health) > 0) HealthChip(health, text: '${view.scored.count(health)} $word'),
                  ],
                ),
                if (step != null) ...[
                  const SizedBox(height: 12),
                  Divider(color: c.divider, height: 1),
                  const SizedBox(height: 10),
                  Text('Langkah pertama', style: AppText.caption.copyWith(color: c.inkMuted)),
                  const SizedBox(height: 2),
                  Text(step, style: AppText.label.copyWith(fontSize: 14, fontWeight: FontWeight.w500)),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
