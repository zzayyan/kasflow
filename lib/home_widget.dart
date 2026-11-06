import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'db.dart';
import 'reports.dart';
import 'screens/plans_tab.dart';

// The Android home screen widget ("Jatah hari ini" with a + for Catat cepat, AllowanceWidget.kt)
// and the launcher shortcut "Catat cepat". This side feeds the widget and answers their launches.

const _channel = MethodChannel('cashflow/notifications');

/// Bumped when the widget's + or the shortcut opens the app; Transaksi then focuses Catat cepat.
final quickInputRequests = ValueNotifier(0);

int _epochDay(DateTime d) => DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

/// Sends the budget Beranda follows to the widget whenever it changes. The widget does the
/// arithmetic itself, so its figure still turns over at midnight while the app stays closed.
/// 'Sembunyikan saldo' covers Beranda only; the widget always shows its figure.
StreamSubscription<void> keepWidgetUpdated() => watchBudgets().listen((budgets) async {
  final b = mainBudget(budgets, pickedId: await getPref('home_budget'));
  final now = DateTime.now();
  await _channel.invokeMethod('updateWidget', {
    'day': _epochDay(now),
    if (b != null) ...{
      'name': b.row['name'],
      'limit': b.row['amount'],
      'spentBefore': b.spent - b.spentToday,
      'spentToday': b.spentToday,
      'endDay': _epochDay(periodRange(b.row['period'] as String, now).$2),
    },
  });
});

/// Opens Catat cepat when the app was started, or brought back, from the widget's + or the shortcut.
void listenForQuickInput() {
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'quickInput') quickInputRequests.value++;
  });
  unawaited(_channel.invokeMethod<bool>('takeQuickInput').then((v) => v == true ? quickInputRequests.value++ : null));
}
