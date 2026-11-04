import 'package:cashflow_app/reports.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('periodElapsed counts today as passed', () {
    expect(periodElapsed('month', DateTime(2026, 11, 4, 13)), closeTo(4 / 30, 1e-9));
    expect(periodElapsed('month', DateTime(2026, 11, 30, 23)), 1.0);
    expect(periodElapsed('week', DateTime(2026, 11, 2)), closeTo(1 / 7, 1e-9)); // Monday
    expect(periodElapsed('year', DateTime(2026, 1, 1)), closeTo(1 / 365, 1e-9));
  });

  test('periodRange: calendar week (Monday), month and year', () {
    final tue = DateTime(2026, 11, 3, 14);
    expect(periodRange('week', tue), (DateTime(2026, 11, 2), DateTime(2026, 11, 9)));
    expect(periodRange('week', DateTime(2026, 11, 8)), (DateTime(2026, 11, 2), DateTime(2026, 11, 9))); // Sunday
    expect(periodRange('month', tue), (DateTime(2026, 11), DateTime(2026, 12)));
    expect(periodRange('month', DateTime(2026, 12, 31)), (DateTime(2026, 12), DateTime(2027)));
    expect(periodRange('year', tue), (DateTime(2026), DateTime(2027)));
  });

  test('buildMonthReport sums types, ranks categories and splits by need level', () {
    final r = buildMonthReport([
      {'type': 'income', 'category_id': 'gaji', 'name': 'Gaji', 'need_level': null, 'cur': 500, 'prev': 400},
      {'type': 'expense', 'category_id': 'makan', 'name': 'Makan', 'need_level': 'need', 'cur': 120, 'prev': 100},
      {'type': 'expense', 'category_id': 'kos', 'name': 'Kos', 'need_level': 'must', 'cur': 200, 'prev': 200},
      {'type': 'expense', 'category_id': null, 'name': null, 'need_level': null, 'cur': 30, 'prev': 0},
      {'type': 'expense', 'category_id': 'game', 'name': 'Game', 'need_level': 'want', 'cur': 0, 'prev': 50},
    ]);
    expect((r.income, r.expense, r.net, r.previousIncome, r.previousExpense), (500, 350, 150, 400, 350));
    expect(r.categories.map((c) => (c.name, c.amount)), [('Kos', 200), ('Makan', 120), ('Tanpa kategori', 30)]);
    expect(r.byNeedLevel, {'must': 200, 'need': 120, null: 30}); // 'want' spent nothing this month
  });

  test('percentChange', () {
    expect(percentChange(120, 100), 20);
    expect(percentChange(80, 100), -20);
    expect(percentChange(50, 0), null);
  });

  test('budget level and daily allowance', () {
    expect(budgetLevel(79, 100), BudgetLevel.ok);
    expect(budgetLevel(80, 100), BudgetLevel.warning);
    expect(budgetLevel(100, 100), BudgetLevel.warning);
    expect(budgetLevel(101, 100), BudgetLevel.over);
    // Nov 3 -> Dec 1: 28 days left including today.
    expect(dailyAllowance(1000, 29000, DateTime(2026, 12), DateTime(2026, 11, 3, 22)), 1000);
    expect(dailyAllowance(100, 100, DateTime(2026, 12), DateTime(2026, 11, 3)), null);
  });

  test('goal plan: monthly amount to the target month, reached, late', () {
    final now = DateTime(2026, 11, 3);
    final p = planGoal(saved: 200, target: 1400, targetDate: DateTime(2027, 5, 1), now: now);
    expect((p.progress, p.remaining, p.perMonth, p.reached, p.late), (200 / 1400, 1200, 200, false, false));
    expect(planGoal(saved: 0, target: 100, targetDate: DateTime(2026, 11, 30), now: now).perMonth, 100);
    expect(planGoal(saved: 0, target: 100, now: now).perMonth, null);
    final reached = planGoal(saved: 150, target: 100, targetDate: DateTime(2026, 1, 1), now: now);
    expect((reached.reached, reached.late, reached.remaining, reached.progress), (true, false, 0, 1.0));
    expect(planGoal(saved: 10, target: 100, targetDate: DateTime(2026, 11, 2), now: now).late, true);
  });
}
