// A5 budgets + A11 cashflow report: pure logic, no Flutter or database, so it is unit-tested.

/// The local-time period [start, end) that contains [day].
/// ponytail: calendar periods only (week starts Monday); payday-anchored months come with 'custom'.
(DateTime, DateTime) periodRange(String period, DateTime day) {
  switch (period) {
    case 'week':
      final start = DateTime(day.year, day.month, day.day - (day.weekday - DateTime.monday));
      return (start, DateTime(start.year, start.month, start.day + 7));
    case 'year':
      return (DateTime(day.year), DateTime(day.year + 1));
    default: // 'month'
      return (DateTime(day.year, day.month), DateTime(day.year, day.month + 1));
  }
}

class CategoryTotal {
  const CategoryTotal(this.id, this.name, this.amount);
  final String? id; // null = records without a category
  final String name;
  final int amount;
}

class MonthReport {
  const MonthReport({
    required this.income,
    required this.expense,
    required this.previousIncome,
    required this.previousExpense,
    required this.categories,
    required this.byNeedLevel,
  });

  final int income;
  final int expense;
  final int previousIncome;
  final int previousExpense;
  final List<CategoryTotal> categories; // this month's expenses, largest first
  final Map<String?, int> byNeedLevel; // 'must' / 'need' / 'want' / null (no level), expenses only

  int get net => income - expense;
  bool get isEmpty => income == 0 && expense == 0;
}

/// [rows] come from the report query: `type`, `category_id`, `name`, `need_level`, `cur`, `prev`
/// (one row per type and category, `cur`/`prev` = sums for this month and the previous one).
MonthReport buildMonthReport(List<Map<String, dynamic>> rows) {
  var income = 0, expense = 0, previousIncome = 0, previousExpense = 0;
  final categories = <CategoryTotal>[];
  final byNeedLevel = <String?, int>{};
  for (final r in rows) {
    final cur = (r['cur'] as int?) ?? 0;
    final prev = (r['prev'] as int?) ?? 0;
    if (r['type'] == 'income') {
      income += cur;
      previousIncome += prev;
      continue;
    }
    expense += cur;
    previousExpense += prev;
    if (cur == 0) continue;
    categories.add(CategoryTotal(r['category_id'] as String?, (r['name'] as String?) ?? 'Tanpa kategori', cur));
    final level = r['need_level'] as String?;
    byNeedLevel[level] = (byNeedLevel[level] ?? 0) + cur;
  }
  categories.sort((a, b) => b.amount.compareTo(a.amount));
  return MonthReport(
    income: income,
    expense: expense,
    previousIncome: previousIncome,
    previousExpense: previousExpense,
    categories: categories,
    byNeedLevel: byNeedLevel,
  );
}

/// Change in percent, or null when there is nothing to compare with.
double? percentChange(int current, int previous) => previous == 0 ? null : (current - previous) / previous * 100;

enum BudgetLevel { ok, warning, over }

BudgetLevel budgetLevel(int spent, int limit) => spent > limit
    ? BudgetLevel.over
    : spent * 10 >= limit * 8
    ? BudgetLevel.warning
    : BudgetLevel.ok;

/// What can still be spent per day until [end] (exclusive), counting today. Null once nothing is left.
int? dailyAllowance(int spent, int limit, DateTime end, DateTime now) {
  final remaining = limit - spent;
  if (remaining <= 0) return null;
  final today = DateTime(now.year, now.month, now.day);
  final days = DateTime(end.year, end.month, end.day).difference(today).inDays;
  return days <= 0 ? null : remaining ~/ days;
}
