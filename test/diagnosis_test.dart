import 'package:cashflow_app/diagnosis.dart';
import 'package:flutter_test/flutter_test.dart';

final oct = DateTime(2026, 10);

DiagRecord rec(
  String type,
  int amount,
  DateTime at, {
  String account = 'bank',
  String? need,
  String? to,
  int? toAmount,
}) => DiagRecord(
  accountId: account,
  type: type,
  amount: amount,
  occurredAt: at,
  needLevel: need,
  transferAccountId: to,
  transferAmount: toAmount ?? (to == null ? null : amount),
);

Pillar pillar(
  PillarKind kind, {
  List<DiagAccount> accounts = const [DiagAccount(id: 'bank', type: 'bank', initialBalance: 0)],
  List<DiagRecord> records = const [],
  List<DiagBill> bills = const [],
  List<DiagBudget> budgets = const [],
  List<DiagGoal> goals = const [],
  DateTime? month,
}) => diagnose(
  month: month ?? oct,
  accounts: accounts,
  records: records,
  bills: bills,
  budgets: budgets,
  goals: goals,
).pillars.firstWhere((p) => p.kind == kind);

void main() {
  test('emergency fund: liquid balance at month end over the average must + need spending', () {
    final p = pillar(
      PillarKind.emergency,
      accounts: const [
        DiagAccount(id: 'bank', type: 'bank', initialBalance: 2464),
        DiagAccount(id: 'saham', type: 'investment', initialBalance: 10000),
      ],
      records: [
        for (final m in [8, 9, 10]) ...[
          rec('expense', 300, DateTime(2026, m, 1), need: 'must'),
          rec('expense', 260, DateTime(2026, m, 12), need: 'need'),
        ],
        rec('expense', 1000, DateTime(2026, 11, 2), need: 'need'), // after October: not counted
      ],
    );
    expect(p.value, closeTo(1.4, 1e-9)); // 784 left / 560 a month
    expect(p.health, Health.bad);
    expect(p.amounts, {'liquid': 784, 'essentials_per_month': 560});
  });

  test('payload for Gemini: rupiah rounded to thousands, goals by name, nothing else', () {
    final d = diagnose(
      month: oct,
      accounts: const [
        DiagAccount(id: 'bank', type: 'bank', initialBalance: 790049900), // Rp 7.900.499
        DiagAccount(id: 'laptop', type: 'savings', initialBalance: 0),
      ],
      records: [
        for (final m in [8, 9, 10]) ...[
          rec('income', 920000000, DateTime(2026, m, 1)),
          rec('expense', 560000000, DateTime(2026, m, 5), need: 'need'),
          rec('expense', 200000000, DateTime(2026, m, 6), need: 'want'),
          rec('transfer', 10000000, DateTime(2026, m, 7), to: 'laptop'),
        ],
      ],
      bills: const [],
      budgets: const [],
      goals: [DiagGoal(name: 'Laptop', accountId: 'laptop', target: 100000000, targetDate: DateTime(2027, 3, 1))],
    );
    final payload = diagnosisPayload(
      d,
      categories: const [CategoryAmount('Belanja Online', 'want', 145049900, 103600000)],
    );
    expect(payload['month'], '2026-10');
    expect(payload['categories'], [
      {'name': 'Belanja Online', 'level': 'want', 'amount': 1450000, 'previous': 1036000},
    ]);
    expect(payload['goals'], [
      {
        'name': 'Laptop',
        'target': 1000000,
        'saved': 300000,
        'target_month': '2027-03',
        'needed_per_month': 175000,
        'saved_per_month': 100000,
      },
    ]);
    final emergency = (payload['pillars'] as List).firstWhere((p) => p['pillar'] == 'emergency');
    expect(emergency['status'], 'bad');
    expect(emergency['liquid'], 12700000); // Rp 12.400.499 in the bank + Rp 300.000 saved, rounded down
    expect(emergency.keys, unorderedEquals(['pillar', 'status', 'value', 'note', 'liquid', 'essentials_per_month']));
  });

  test('emergency fund and spending go unknown when over 20% of spending has no need level', () {
    final records = [
      rec('expense', 700, DateTime(2026, 10, 3), need: 'need'),
      rec('expense', 210, DateTime(2026, 10, 4)), // 21% of 1000 without a level
      rec('expense', 90, DateTime(2026, 10, 5), need: 'want'),
    ];
    for (final kind in [PillarKind.emergency, PillarKind.spending]) {
      final p = pillar(
        kind,
        accounts: const [DiagAccount(id: 'bank', type: 'bank', initialBalance: 5000)],
        records: records,
      );
      expect(p.health, Health.unknown, reason: '$kind');
      expect(p.reason, 'Atur tingkat kebutuhan kategori');
    }
  });

  test('spending: the want share, 30% still good, over 40% bad', () {
    Health health(int want) => pillar(
      PillarKind.spending,
      records: [
        rec('expense', 1000 - want, DateTime(2026, 10, 3), need: 'need'),
        rec('expense', want, DateTime(2026, 10, 4), need: 'want'),
      ],
    ).health;
    expect(health(300), Health.good);
    expect(health(350), Health.warn);
    expect(health(410), Health.bad);
  });

  test('savings: the 3-month savings rate, and bad with no income at all', () {
    final p = pillar(
      PillarKind.savings,
      records: [
        for (final m in [8, 9, 10]) ...[
          rec('income', 1000, DateTime(2026, m, 1)),
          rec('expense', 850, DateTime(2026, m, 9), need: 'need'),
        ],
        rec('income', 5000, DateTime(2026, 7, 1)), // before the window
      ],
    );
    expect(p.value, closeTo(0.15, 1e-9));
    expect(p.health, Health.warn);

    final none = pillar(PillarKind.savings, records: [rec('expense', 100, DateTime(2026, 10, 2), need: 'need')]);
    expect(none.health, Health.bad);
    expect(none.reason, 'Tidak ada pemasukan tercatat');
  });

  test('fixed costs: expense bills per month over the average monthly income', () {
    final income = [
      for (final m in [8, 9, 10]) rec('income', 1000, DateTime(2026, m, 1)),
    ];
    final p = pillar(
      PillarKind.fixedCosts,
      records: income,
      bills: const [
        DiagBill(type: 'expense', amount: 200, rule: 'FREQ=MONTHLY;BYMONTHDAY=5'),
        DiagBill(type: 'expense', amount: 30, rule: 'FREQ=WEEKLY'), // 130 a month
        DiagBill(type: 'expense', amount: 1200, rule: 'FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=1'), // 100 a month
        DiagBill(type: 'expense', amount: 300, rule: 'FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1'), // 100 a month
        DiagBill(type: 'income', amount: 500, rule: 'FREQ=MONTHLY;BYMONTHDAY=25'),
      ],
    );
    expect(p.value, closeTo(0.53, 1e-9));
    expect(p.health, Health.bad);

    expect(pillar(PillarKind.fixedCosts, records: income).health, Health.good); // no bills
  });

  group('debt', () {
    const accounts = [
      DiagAccount(id: 'bank', type: 'bank', initialBalance: 100000),
      DiagAccount(id: 'kpr', type: 'loan', initialBalance: -50000),
      DiagAccount(id: 'cc', type: 'credit_card', initialBalance: 0),
    ];
    final income = [
      for (final m in [8, 9, 10]) rec('income', 1000, DateTime(2026, m, 1)),
    ];
    List<DiagRecord> installments(int amount) => [
      for (final m in [8, 9, 10]) rec('transfer', amount, DateTime(2026, m, 3), to: 'kpr'),
    ];
    final ccSpending = [
      for (final m in [8, 9, 10]) rec('expense', 100, DateTime(2026, m, 20), account: 'cc'),
    ];

    test('installments into loan accounts over income: 30% good, over 40% bad', () {
      final ok = pillar(PillarKind.debt, accounts: accounts, records: [...income, ...installments(250)]);
      expect(ok.value, closeTo(0.25, 1e-9));
      expect(ok.health, Health.good);
      expect(
        pillar(PillarKind.debt, accounts: accounts, records: [...income, ...installments(350)]).health,
        Health.warn,
      );
      expect(
        pillar(PillarKind.debt, accounts: accounts, records: [...income, ...installments(410)]).health,
        Health.bad,
      );
    });

    test('a credit card balance that grows two months running is a warning', () {
      final p = pillar(PillarKind.debt, accounts: accounts, records: [...income, ...ccSpending]);
      expect(p.health, Health.warn);
      expect(p.reason, 'Tagihan kartu kredit menumpuk 2 bulan');

      final paid = rec('transfer', 200, DateTime(2026, 10, 25), to: 'cc'); // October paid off
      expect(
        pillar(PillarKind.debt, accounts: accounts, records: [...income, ...ccSpending, paid]).health,
        Health.good,
      );
    });

    test('no debt accounts at all is good', () {
      final p = pillar(
        PillarKind.debt,
        accounts: const [DiagAccount(id: 'bank', type: 'bank', initialBalance: 0)],
      );
      expect(p.health, Health.good);
      expect(p.value, 0);
    });
  });

  test('budgets: none over is good, up to a third over a warning, more bad, none set unknown', () {
    Health health(List<(int, int)> b) => pillar(
      PillarKind.budgets,
      budgets: [for (final (spent, limit) in b) DiagBudget(spent: spent, limit: limit)],
    ).health;
    expect(health([(100, 100), (50, 80), (0, 10)]), Health.good); // spending the whole limit is not over
    expect(health([(101, 100), (50, 80), (0, 10)]), Health.warn);
    expect(health([(101, 100), (90, 80), (0, 10)]), Health.bad);

    final none = pillar(PillarKind.budgets);
    expect(none.health, Health.unknown);
    expect(none.reason, 'Belum ada anggaran');
  });

  group('goals', () {
    const accounts = [
      DiagAccount(id: 'bank', type: 'bank', initialBalance: 100000),
      DiagAccount(id: 'laptop', type: 'savings', initialBalance: 0),
    ];
    List<DiagRecord> saving(int perMonth) => [
      for (final m in [8, 9, 10]) rec('transfer', perMonth, DateTime(2026, m, 2), to: 'laptop'),
    ];
    Pillar goal(int perMonth, DateTime? date) => pillar(
      PillarKind.goals,
      accounts: accounts,
      records: saving(perMonth),
      goals: [DiagGoal(name: 'Laptop', accountId: 'laptop', target: 1000, targetDate: date)],
    );

    test('on track when the last 3 months saved at least what the target date needs', () {
      // 600 saved by October; 400 left over Nov to Mar = 100 a month, and the pace is 200.
      expect(goal(200, DateTime(2027, 3, 1)).health, Health.good);
    });

    test('behind is a warning, and bad when the date is under 3 months away', () {
      final behind = goal(100, DateTime(2027, 3, 1)); // needs 175 a month, saves 100
      expect(behind.health, Health.warn);
      expect(behind.value, 1);
      expect(goal(100, DateTime(2027, 1, 1)).health, Health.bad); // needs 350 a month
    });

    test('a target date already passed is bad; goals without a date are not scored', () {
      expect(goal(100, DateTime(2026, 9, 1)).health, Health.bad);
      final undated = goal(100, null);
      expect(undated.health, Health.unknown);
      expect(undated.reason, 'Belum ada target bertanggal');
    });
  });

  test('net worth: every account, excluded ones too, against 3 month ends earlier', () {
    const accounts = [
      DiagAccount(id: 'bank', type: 'bank', initialBalance: 1000),
      DiagAccount(id: 'emas', type: 'investment', initialBalance: 500, excluded: true),
      DiagAccount(id: 'kpr', type: 'loan', initialBalance: -400),
    ];
    Pillar worth(List<DiagRecord> records) => pillar(PillarKind.netWorth, accounts: accounts, records: records);

    final up = worth([rec('income', 300, DateTime(2026, 9, 1), account: 'emas')]);
    expect(up.value, 1400); // 1000 + 800 - 400
    expect(up.health, Health.good);
    expect(worth([]).health, Health.good); // flat
    expect(worth([rec('expense', 50, DateTime(2026, 8, 1), need: 'want')]).health, Health.warn);
    expect(worth([rec('expense', 50, DateTime(2026, 7, 1), need: 'want')]).health, Health.good); // before the window
    expect(worth([rec('expense', 1200, DateTime(2026, 10, 1), need: 'want')]).health, Health.bad); // below zero
  });

  test('records on an excluded account stay out of cash flow', () {
    final p = pillar(
      PillarKind.savings,
      accounts: const [
        DiagAccount(id: 'bank', type: 'bank', initialBalance: 0),
        DiagAccount(id: 'kantor', type: 'bank', initialBalance: 0, excluded: true),
      ],
      records: [
        rec('income', 1000, DateTime(2026, 10, 1)),
        rec('expense', 750, DateTime(2026, 10, 2), need: 'need'),
        rec('income', 5000, DateTime(2026, 10, 3), account: 'kantor'),
      ],
    );
    expect(p.value, closeTo(0.25, 1e-9));
  });

  test('pillars come worst first, unknown last, and are counted per health', () {
    final d = diagnose(
      month: oct,
      accounts: const [DiagAccount(id: 'bank', type: 'bank', initialBalance: 1800)],
      records: [
        rec('income', 1000, DateTime(2026, 10, 1)),
        rec('expense', 600, DateTime(2026, 10, 2), need: 'need'),
        rec('expense', 400, DateTime(2026, 10, 3), need: 'want'),
      ],
      bills: const [],
      budgets: const [],
      goals: const [],
    );
    // emergency 3 months: warn; savings 0%: bad; want 40%: warn; no bills, no debt, flat worth:
    // good; no budgets or goals: unknown.
    expect(d.pillars.map((p) => p.kind), [
      PillarKind.savings,
      PillarKind.emergency,
      PillarKind.spending,
      PillarKind.fixedCosts,
      PillarKind.debt,
      PillarKind.netWorth,
      PillarKind.budgets,
      PillarKind.goals,
    ]);
    expect(d.count(Health.good), 3);
    expect(d.count(Health.warn), 2);
    expect(d.count(Health.bad), 1);
    expect(d.count(Health.unknown), 2);
  });

  test('averages cover only the months since the first record, not three empty ones', () {
    final d = diagnose(
      month: oct,
      accounts: const [DiagAccount(id: 'bank', type: 'bank', initialBalance: 1000)],
      records: [
        for (final m in [9, 10]) ...[
          rec('income', 1000, DateTime(2026, m, 1)),
          rec('expense', 500, DateTime(2026, m, 3), need: 'must'),
        ],
      ],
      bills: const [DiagBill(type: 'expense', amount: 300, rule: 'FREQ=MONTHLY;BYMONTHDAY=1')],
      budgets: const [],
      goals: const [],
    );
    Pillar p(PillarKind k) => d.pillars.firstWhere((p) => p.kind == k);
    expect(p(PillarKind.emergency).value, closeTo(4, 1e-9)); // 2000 left / 500 a month over 2 months
    expect(p(PillarKind.emergency).amounts['essentials_per_month'], 500);
    expect(p(PillarKind.fixedCosts).value, closeTo(0.3, 1e-9)); // 300 / 1000 a month
  });

  test('records on an archived account (one the caller left out) stay out of cash flow', () {
    final p = pillar(
      PillarKind.savings,
      accounts: const [DiagAccount(id: 'bank', type: 'bank', initialBalance: 0)],
      records: [
        rec('income', 1000, DateTime(2026, 10, 1)),
        rec('expense', 750, DateTime(2026, 10, 2), need: 'need'),
        rec('income', 5000, DateTime(2026, 10, 3), account: 'lama'), // archived
      ],
    );
    expect(p.value, closeTo(0.25, 1e-9));
  });

  test('a first month recorded only in part counts as part of a month', () {
    // Recording starts 25 Sep: 6 of September's 30 days and all of October are 1.2 months, not 2.
    final p = pillar(
      PillarKind.fixedCosts,
      records: [rec('income', 300, DateTime(2026, 9, 25)), rec('income', 1000, DateTime(2026, 10, 1))],
      bills: const [DiagBill(type: 'expense', amount: 300, rule: 'FREQ=MONTHLY;BYMONTHDAY=1')],
    );
    expect(p.amounts['income_per_month'], 1083); // 1300 / 1.2
  });

  test('excluded accounts are left out of the emergency fund', () {
    final p = pillar(
      PillarKind.emergency,
      accounts: const [
        DiagAccount(id: 'bank', type: 'bank', initialBalance: 1500),
        DiagAccount(id: 'kantor', type: 'bank', initialBalance: 9000, excluded: true),
      ],
      records: [rec('expense', 500, DateTime(2026, 8, 1), need: 'must')],
    );
    expect(p.amounts['liquid'], 1000);
  });

  test('emergency fund is unknown without any must or need spending', () {
    final p = pillar(
      PillarKind.emergency,
      accounts: const [DiagAccount(id: 'bank', type: 'bank', initialBalance: 5000)],
    );
    expect(p.health, Health.unknown);
    expect(p.reason, 'Belum ada pengeluaran wajib atau butuh');
  });
}
