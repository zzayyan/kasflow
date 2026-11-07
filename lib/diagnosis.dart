// Diagnosis CFO: eight health pillars for one full month. Pure logic, no Flutter or database, so it
// is unit-tested. Gemini only words the result; every number and status comes from here.

import 'recurrence.dart';
import 'reports.dart';

enum Health { good, warn, bad, unknown }

enum PillarKind { emergency, savings, spending, fixedCosts, goals, debt, budgets, netWorth }

class Pillar {
  const Pillar(this.kind, this.health, {this.value, this.reason});
  final PillarKind kind;
  final Health health;
  final double? value; // in the pillar's own unit: months, a 0..1 share, rupiah, a count
  final String? reason; // why it could not be measured, or why it is bad without a value
}

class Diagnosis {
  /// Sorts [pillars] worst first (bad, warn, good) with unknown last; ties keep their order.
  // Grouped rather than sorted: List.sort is not guaranteed stable.
  Diagnosis(List<Pillar> pillars)
    : pillars = [
        for (final h in const [Health.bad, Health.warn, Health.good, Health.unknown])
          ...pillars.where((p) => p.health == h),
      ];
  final List<Pillar> pillars;

  int count(Health health) => pillars.where((p) => p.health == health).length;
}

class DiagAccount {
  const DiagAccount({required this.id, required this.type, required this.initialBalance, this.excluded = false});
  final String id;
  final String type; // cash, bank, ewallet, credit_card, savings, investment, loan
  final int initialBalance;
  final bool excluded; // exclude_from_stats: out of cash flow, still in net worth and debt
}

/// A confirmed record. [occurredAt] is local time.
class DiagRecord {
  const DiagRecord({
    required this.accountId,
    required this.type,
    required this.amount,
    required this.occurredAt,
    this.needLevel,
    this.transferAccountId,
    this.transferAmount,
  });
  final String accountId;
  final String type; // income, expense, transfer
  final int amount;
  final DateTime occurredAt;
  final String? needLevel; // must, need, want, or null
  final String? transferAccountId;
  final int? transferAmount;
}

class DiagBill {
  const DiagBill({required this.type, required this.amount, required this.rule});
  final String type;
  final int amount;
  final String rule;
}

/// One budget period that ended in the month, with what was spent in it. A yearly budget still
/// running comes with its limit scaled by periodElapsed, so it is judged by its pace.
class DiagBudget {
  const DiagBudget({required this.spent, required this.limit});
  final int spent;
  final int limit;
}

class DiagGoal {
  const DiagGoal({required this.accountId, required this.target, this.targetDate});
  final String accountId;
  final int target;
  final DateTime? targetDate;
}

const _liquid = {'cash', 'bank', 'ewallet', 'savings'};

/// Scores [month] (any day in it; a full month that has ended).
Diagnosis diagnose({
  required DateTime month,
  required List<DiagAccount> accounts,
  required List<DiagRecord> records,
  required List<DiagBill> bills,
  required List<DiagBudget> budgets,
  required List<DiagGoal> goals,
}) {
  final end = DateTime(month.year, month.month + 1); // exclusive
  final windowStart = DateTime(month.year, month.month - 2); // the 3-month average starts here
  final balances = _balances(accounts, records, end);

  final excluded = {
    for (final a in accounts)
      if (a.excluded) a.id,
  };
  final flow = [
    for (final r in records)
      if (!excluded.contains(r.accountId) && !r.occurredAt.isBefore(windowStart) && r.occurredAt.isBefore(end)) r,
  ];
  int sum(bool Function(DiagRecord r) test) => flow.where(test).fold(0, (s, r) => s + r.amount);
  final income = sum((r) => r.type == 'income');
  final expense = sum((r) => r.type == 'expense');
  final unleveled = sum((r) => r.type == 'expense' && r.needLevel == null);
  final essentials = sum((r) => r.type == 'expense' && (r.needLevel == 'must' || r.needLevel == 'need')) / 3;
  final want = sum((r) => r.type == 'expense' && r.needLevel == 'want');
  const setLevels = 'Atur tingkat kebutuhan kategori';
  final levelsUnclear = unleveled * 5 > expense; // over 20%

  final liquid = accounts.where((a) => _liquid.contains(a.type)).fold(0, (s, a) => s + balances[a.id]!);

  Pillar emergency() {
    if (levelsUnclear) return const Pillar(PillarKind.emergency, Health.unknown, reason: setLevels);
    if (essentials == 0) {
      return const Pillar(PillarKind.emergency, Health.unknown, reason: 'Belum ada pengeluaran wajib atau butuh');
    }
    final months = liquid / essentials;
    return Pillar(PillarKind.emergency, _band(months, bad: 3, good: 6), value: months);
  }

  Pillar savings() {
    if (income == 0) return const Pillar(PillarKind.savings, Health.bad, reason: 'Tidak ada pemasukan tercatat');
    final rate = (income - expense) / income;
    return Pillar(PillarKind.savings, _band(rate, bad: 0.1, good: 0.2), value: rate);
  }

  Pillar fixedCosts() {
    final perMonth = bills.where((b) => b.type == 'expense').fold(0.0, (s, b) => s + _monthly(b));
    if (perMonth == 0) return const Pillar(PillarKind.fixedCosts, Health.good, value: 0);
    if (income == 0) return const Pillar(PillarKind.fixedCosts, Health.bad, reason: 'Tidak ada pemasukan tercatat');
    final share = perMonth / (income / 3);
    return Pillar(PillarKind.fixedCosts, _bandLow(share, good: 0.3, bad: 0.5), value: share);
  }

  Pillar debt() {
    final loans = {
      for (final a in accounts)
        if (a.type == 'loan') a.id,
    };
    final cards = [
      for (final a in accounts)
        if (a.type == 'credit_card') a.id,
    ];
    if (loans.isEmpty && cards.isEmpty) return const Pillar(PillarKind.debt, Health.good, value: 0);
    // Installments: what moved into a loan account, from any account, excluded ones too.
    final paid = records
        .where((r) => r.type == 'transfer' && loans.contains(r.transferAccountId))
        .where((r) => !r.occurredAt.isBefore(windowStart) && r.occurredAt.isBefore(end))
        .fold(0, (s, r) => s + (r.transferAmount ?? 0));
    if (paid > 0 && income == 0) {
      return const Pillar(PillarKind.debt, Health.bad, reason: 'Tidak ada pemasukan tercatat');
    }
    final share = paid == 0 ? 0.0 : paid / income;
    final health = _bandLow(share, good: 0.3, bad: 0.4);
    // A card owed more at each of the last three month ends is not being paid off.
    final endTwoBack = _balances(accounts, records, DateTime(month.year, month.month - 1));
    final endOneBack = _balances(accounts, records, DateTime(month.year, month.month));
    final piling = cards.any((c) => balances[c]! < endOneBack[c]! && endOneBack[c]! < endTwoBack[c]!);
    if (piling && health == Health.good) {
      return Pillar(PillarKind.debt, Health.warn, value: share, reason: 'Tagihan kartu kredit menumpuk 2 bulan');
    }
    return Pillar(PillarKind.debt, health, value: share);
  }

  Pillar spending() {
    if (levelsUnclear) return const Pillar(PillarKind.spending, Health.unknown, reason: setLevels);
    final share = expense == 0 ? 0.0 : want / expense;
    return Pillar(PillarKind.spending, _bandLow(share, good: 0.3, bad: 0.4), value: share);
  }

  Pillar budgetsPillar() {
    if (budgets.isEmpty) return const Pillar(PillarKind.budgets, Health.unknown, reason: 'Belum ada anggaran');
    final over = budgets.where((b) => b.spent > b.limit).length;
    final health = over == 0 ? Health.good : (over * 3 <= budgets.length ? Health.warn : Health.bad);
    return Pillar(PillarKind.budgets, health, value: over.toDouble());
  }

  Pillar goalsPillar() {
    final dated = [
      for (final g in goals)
        if (g.targetDate != null) g,
    ];
    if (dated.isEmpty) return const Pillar(PillarKind.goals, Health.unknown, reason: 'Belum ada target bertanggal');
    final threeBack = _balances(accounts, records, windowStart);
    var behind = 0, urgent = false;
    for (final g in dated) {
      final saved = balances[g.accountId] ?? 0;
      final plan = planGoal(saved: saved, target: g.target, targetDate: g.targetDate, now: end);
      if (plan.reached) continue;
      final pace = (saved - (threeBack[g.accountId] ?? 0)) / 3;
      if (!plan.late && pace >= plan.perMonth!) continue;
      behind++;
      final monthsLeft = (g.targetDate!.year - end.year) * 12 + g.targetDate!.month - end.month;
      if (plan.late || monthsLeft < 3) urgent = true;
    }
    final health = behind == 0 ? Health.good : (urgent ? Health.bad : Health.warn);
    return Pillar(PillarKind.goals, health, value: behind.toDouble());
  }

  Pillar netWorth() {
    int total(Map<String, int> b) => b.values.fold(0, (s, v) => s + v);
    final now = total(balances);
    final then = total(_balances(accounts, records, windowStart));
    final health = now < 0 ? Health.bad : (now < then ? Health.warn : Health.good);
    return Pillar(PillarKind.netWorth, health, value: now.toDouble());
  }

  return Diagnosis([
    emergency(),
    savings(),
    spending(),
    fixedCosts(),
    debt(),
    budgetsPillar(),
    goalsPillar(),
    netWorth(),
  ]);
}

/// A bill's amount per month: weekly times 52/12, yearly over 12, both over INTERVAL.
double _monthly(DiagBill b) {
  final interval = int.tryParse(RegExp(r'INTERVAL=(\d+)').firstMatch(b.rule)?.group(1) ?? '') ?? 1;
  final perMonth = switch (frequencyOf(b.rule)) {
    'WEEKLY' => b.amount * 52 / 12,
    'YEARLY' => b.amount / 12,
    _ => b.amount.toDouble(),
  };
  return perMonth / interval;
}

/// Higher is better: below [bad] is bad, from [good] up is good, between is a warning.
Health _band(double v, {required double bad, required double good}) =>
    v < bad ? Health.bad : (v >= good ? Health.good : Health.warn);

/// Lower is better: up to [good] is good, above [bad] is bad, between is a warning.
Health _bandLow(double v, {required double good, required double bad}) =>
    v > bad ? Health.bad : (v <= good ? Health.good : Health.warn);

/// Balance per account at [end] (exclusive), the way accountBalancesSql in db.dart derives it.
Map<String, int> _balances(List<DiagAccount> accounts, List<DiagRecord> records, DateTime end) {
  final b = {for (final a in accounts) a.id: a.initialBalance};
  for (final r in records) {
    if (!r.occurredAt.isBefore(end)) continue;
    if (b.containsKey(r.accountId)) b[r.accountId] = b[r.accountId]! + (r.type == 'income' ? r.amount : -r.amount);
    final to = r.transferAccountId;
    if (r.type == 'transfer' && to != null && b.containsKey(to)) b[to] = b[to]! + (r.transferAmount ?? 0);
  }
  return b;
}
