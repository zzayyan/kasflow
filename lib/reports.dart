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

/// How much of the period around [now] has passed, 0 to 1, counting today as passed: the "today"
/// marker on a budget bar. Spending ahead of it runs out before the period ends.
double periodElapsed(String period, DateTime now) {
  final (start, end) = periodRange(period, now);
  final days = end.difference(start).inHours / 24; // hours: a DST day is 23 or 25 hours long
  final passed = DateTime(now.year, now.month, now.day + 1).difference(start).inHours / 24;
  return (passed / days).clamp(0.0, 1.0);
}

class CategoryTotal {
  const CategoryTotal(this.id, this.name, this.amount, [this.previous = 0]);
  final String? id; // null = records without a category
  final String name;
  final int amount;
  final int previous; // the same category in the month before
}

class MonthReport {
  const MonthReport({
    required this.income,
    required this.expense,
    required this.previousIncome,
    required this.previousExpense,
    required this.categories,
    required this.incomeCategories,
    required this.byNeedLevel,
  });

  final int income;
  final int expense;
  final int previousIncome;
  final int previousExpense;
  final List<CategoryTotal> categories; // this month's expenses, largest first
  final List<CategoryTotal> incomeCategories; // this month's income, largest first
  final Map<String?, int> byNeedLevel; // 'must' / 'need' / 'want' / null (no level), expenses only

  int get net => income - expense;
  bool get isEmpty => income == 0 && expense == 0;
}

/// [rows] come from the report query: `type`, `category_id`, `name`, `need_level`, `cur`, `prev`
/// (one row per type and category, `cur`/`prev` = sums for this month and the previous one).
MonthReport buildMonthReport(List<Map<String, dynamic>> rows) {
  var income = 0, expense = 0, previousIncome = 0, previousExpense = 0;
  final categories = <CategoryTotal>[];
  final incomeCategories = <CategoryTotal>[];
  final byNeedLevel = <String?, int>{};
  for (final r in rows) {
    final cur = (r['cur'] as int?) ?? 0;
    final prev = (r['prev'] as int?) ?? 0;
    final total = CategoryTotal(r['category_id'] as String?, (r['name'] as String?) ?? 'Tanpa kategori', cur, prev);
    if (r['type'] == 'income') {
      income += cur;
      previousIncome += prev;
      if (cur > 0) incomeCategories.add(total);
      continue;
    }
    expense += cur;
    previousExpense += prev;
    if (cur == 0) continue;
    categories.add(total);
    final level = r['need_level'] as String?;
    byNeedLevel[level] = (byNeedLevel[level] ?? 0) + cur;
  }
  int largestFirst(CategoryTotal a, CategoryTotal b) => b.amount.compareTo(a.amount);
  categories.sort(largestFirst);
  incomeCategories.sort(largestFirst);
  return MonthReport(
    income: income,
    expense: expense,
    previousIncome: previousIncome,
    previousExpense: previousExpense,
    categories: categories,
    incomeCategories: incomeCategories,
    byNeedLevel: byNeedLevel,
  );
}

/// The categories that own the chart hues: the first [count] of [type] in [rows] (`type`,
/// `category_id`, largest total first), so a category keeps its color from month to month.
List<String?> topCategories(List<Map<String, dynamic>> rows, String type, int count) =>
    [for (final r in rows) if (r['type'] == type) r['category_id'] as String?].take(count).toList();

/// The category chart for one month ([month] largest first). Each category of [top] stays itself
/// and keeps its hue; the rest fold into one gray "Lainnya" at the end, or stay themselves when
/// only one is left over. [rest] lists what that last gray part holds; empty when none.
({List<CategoryTotal> parts, List<CategoryTotal> rest}) chartParts(List<CategoryTotal> month, List<String?> top) {
  final kept = [for (final c in month) if (top.contains(c.id)) c];
  final rest = [for (final c in month) if (!top.contains(c.id)) c];
  if (rest.isEmpty) return (parts: kept, rest: rest);
  final gray = rest.length == 1
      ? rest.single
      : CategoryTotal(
          null,
          'Lainnya',
          rest.fold<int>(0, (sum, c) => sum + c.amount),
          rest.fold<int>(0, (sum, c) => sum + c.previous),
        );
  return (parts: [...kept, gray], rest: rest);
}

/// Totals of [type] for the [count] months ending with [lastMonth], oldest first. [rows] hold
/// `type`, `amount` and `occurred_at` (UTC ISO 8601); months are local calendar months.
List<int> monthTotals(List<Map<String, dynamic>> rows, DateTime lastMonth, int count, String type) {
  final totals = List.filled(count, 0);
  for (final r in rows) {
    if (r['type'] != type) continue;
    final t = DateTime.parse(r['occurred_at'] as String).toLocal();
    final back = (lastMonth.year - t.year) * 12 + lastMonth.month - t.month;
    if (back >= 0 && back < count) totals[count - 1 - back] += r['amount'] as int;
  }
  return totals;
}

/// Totals of [type] for the [count] days ending with [lastDay], oldest first, by local date.
List<int> dayTotals(List<Map<String, dynamic>> rows, DateTime lastDay, int count, String type) {
  final last = DateTime(lastDay.year, lastDay.month, lastDay.day);
  final totals = List.filled(count, 0);
  for (final r in rows) {
    if (r['type'] != type) continue;
    final t = DateTime.parse(r['occurred_at'] as String).toLocal();
    // Calendar days, not 24-hour blocks: a DST day is 23 or 25 hours long.
    final back = DateTime.utc(last.year, last.month, last.day).difference(DateTime.utc(t.year, t.month, t.day)).inDays;
    if (back >= 0 && back < count) totals[count - 1 - back] += r['amount'] as int;
  }
  return totals;
}

/// Axis ticks from 0 in steps of 1, 2 or 5 x 10^n, [count] steps up to at least [max].
List<int> niceTicks(int max, {int count = 3}) {
  if (max <= 0) return [0];
  final raw = max / count;
  var magnitude = 1;
  while (magnitude * 10 <= raw) {
    magnitude *= 10;
  }
  final step = [1, 2, 5, 10].map((m) => m * magnitude).firstWhere((s) => s >= raw);
  return [for (var i = 0; i <= count; i++) i * step];
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

/// Today's allowance, fixed at the start of the day from what was spent before today, and what is
/// left of it after today's spending ([spent] includes [spentToday]). `left` goes negative once
/// today's spending passes the allowance. Null when the budget had nothing left before today.
({int perDay, int left})? todayAllowance(int spent, int spentToday, int limit, DateTime end, DateTime now) {
  final perDay = dailyAllowance(spent - spentToday, limit, end, now);
  return perDay == null ? null : (perDay: perDay, left: perDay - spentToday);
}

class GoalPlan {
  const GoalPlan({
    required this.progress,
    required this.remaining,
    required this.reached,
    this.perMonth,
    this.late = false,
  });

  final double progress; // 0..1
  final int remaining; // 0 once reached
  final bool reached;
  final int? perMonth; // to save each month to reach the target date; null without a date
  final bool late; // target date passed and not reached
}

/// Progress of a saving goal whose [saved] amount is the linked account's balance.
/// Months left counts calendar months from now to the target month, at least 1, so a target later
/// this month asks for the whole remainder now.
GoalPlan planGoal({required int saved, required int target, DateTime? targetDate, required DateTime now}) {
  final remaining = (target - saved).clamp(0, target);
  final reached = saved >= target;
  final progress = target <= 0 ? 1.0 : (saved / target).clamp(0.0, 1.0);
  if (reached || targetDate == null) return GoalPlan(progress: progress, remaining: remaining, reached: reached);
  final today = DateTime(now.year, now.month, now.day);
  if (targetDate.isBefore(today)) {
    return GoalPlan(progress: progress, remaining: remaining, reached: false, late: true);
  }
  final months = (targetDate.year - now.year) * 12 + targetDate.month - now.month;
  return GoalPlan(
    progress: progress,
    remaining: remaining,
    reached: false,
    perMonth: (remaining / (months < 1 ? 1 : months)).ceil(),
  );
}
