import 'package:cashflow_app/recurrence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('monthly keeps its anchor day and clamps short months', () {
    final rule = buildRule('MONTHLY', DateTime(2026, 1, 31));
    expect(rule, 'FREQ=MONTHLY;BYMONTHDAY=31');
    var due = DateTime(2026, 1, 31);
    final dues = [for (var i = 0; i < 4; i++) due = nextDueDate(rule, due)];
    expect(dues, [DateTime(2026, 2, 28), DateTime(2026, 3, 31), DateTime(2026, 4, 30), DateTime(2026, 5, 31)]);
    expect(nextDueDate(rule, DateTime(2026, 12, 31)), DateTime(2027, 1, 31)); // year rollover
  });

  test('weekly, yearly and interval', () {
    expect(nextDueDate('FREQ=WEEKLY', DateTime(2026, 12, 29)), DateTime(2027, 1, 5));
    final leap = buildRule('YEARLY', DateTime(2028, 2, 29));
    expect(nextDueDate(leap, DateTime(2028, 2, 29)), DateTime(2029, 2, 28));
    expect(nextDueDate(leap, DateTime(2031, 2, 28)), DateTime(2032, 2, 29));
    expect(nextDueDate('FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=10', DateTime(2026, 11, 10)), DateTime(2027, 2, 10));
    expect(frequencyOf(leap), 'YEARLY');
  });

  test('due status and labels', () {
    final now = DateTime(2026, 11, 3, 20);
    expect(dueStatus(DateTime(2026, 11, 1), 1, now), (-2, DueLevel.overdue));
    expect(dueStatus(DateTime(2026, 11, 3), 0, now), (0, DueLevel.soon));
    expect(dueStatus(DateTime(2026, 11, 6), 3, now), (3, DueLevel.soon));
    expect(dueStatus(DateTime(2026, 11, 7), 3, now), (4, DueLevel.upcoming));
    expect(
      [dueLabel(-2), dueLabel(-1), dueLabel(0), dueLabel(1), dueLabel(5)],
      ['Terlambat 2 hari', 'Terlambat 1 hari', 'Hari ini', 'Besok', '5 hari lagi'],
    );
  });

  test('reminder at 09:00, crossing month starts', () {
    expect(reminderAt(DateTime(2026, 12, 2), 3), DateTime(2026, 11, 29, 9));
    expect(reminderAt(DateTime(2026, 12, 2), 0), DateTime(2026, 12, 2, 9));
  });
}
