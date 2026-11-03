// A7 planned payments: recurrence, due status and reminder times. Pure logic, unit-tested.

/// Builds the stored rule (a subset of RFC 5545) anchored on [firstDue], so a bill due on the 31st
/// stays on the 31st (or the last day of shorter months) instead of drifting to the 28th.
String buildRule(String freq, DateTime firstDue) => switch (freq) {
  'WEEKLY' => 'FREQ=WEEKLY',
  'YEARLY' => 'FREQ=YEARLY;BYMONTH=${firstDue.month};BYMONTHDAY=${firstDue.day}',
  _ => 'FREQ=MONTHLY;BYMONTHDAY=${firstDue.day}',
};

/// The due date after [due]. Understands FREQ (WEEKLY/MONTHLY/YEARLY), INTERVAL, BYMONTH, BYMONTHDAY.
DateTime nextDueDate(String rule, DateTime due) {
  final p = {
    for (final part in rule.split(';'))
      if (part.contains('=')) part.split('=')[0].trim().toUpperCase(): part.split('=')[1].trim(),
  };
  final interval = int.tryParse(p['INTERVAL'] ?? '') ?? 1;
  final day = int.tryParse(p['BYMONTHDAY'] ?? '') ?? due.day;
  return switch (p['FREQ']) {
    'WEEKLY' => DateTime(due.year, due.month, due.day + 7 * interval),
    'YEARLY' => _clamped(due.year + interval, int.tryParse(p['BYMONTH'] ?? '') ?? due.month, day),
    _ => _clamped(due.year, due.month + interval, day),
  };
}

/// Day [day] of month [month], or that month's last day when it is shorter. Months past 12 roll over.
DateTime _clamped(int year, int month, int day) {
  final last = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day > last ? last : day);
}

String frequencyOf(String rule) => rule.contains('FREQ=WEEKLY')
    ? 'WEEKLY'
    : rule.contains('FREQ=YEARLY')
    ? 'YEARLY'
    : 'MONTHLY';

enum DueLevel { upcoming, soon, overdue }

/// Days until [due] (negative when late) and how urgent it is: "soon" inside the reminder window.
(int days, DueLevel level) dueStatus(DateTime due, int remindDaysBefore, DateTime now) {
  final days = DateTime(due.year, due.month, due.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  final level = days < 0
      ? DueLevel.overdue
      : days <= remindDaysBefore
      ? DueLevel.soon
      : DueLevel.upcoming;
  return (days, level);
}

String dueLabel(int days) => switch (days) {
  < -1 => 'Terlambat ${-days} hari',
  -1 => 'Terlambat 1 hari',
  0 => 'Hari ini',
  1 => 'Besok',
  _ => '$days hari lagi',
};

/// Reminders fire at 09:00 local time, [daysBefore] days before the due date.
DateTime reminderAt(DateTime due, int daysBefore) => DateTime(due.year, due.month, due.day - daysBefore, 9);
