import 'package:cashflow_app/screens/plans_tab.dart';
import 'package:flutter_test/flutter_test.dart';

BudgetView budget(String name, String period, int amount) =>
    BudgetView({'id': name, 'name': name, 'period': period, 'amount': amount}, 0);

void main() {
  test('mainBudget: monthly before weekly before yearly, then the largest', () {
    final pick = mainBudget([
      budget('Liburan', 'year', 1000000000),
      budget('Jajan', 'week', 20000000),
      budget('Kopi', 'month', 30000000),
      budget('Biaya hidup', 'month', 250000000),
    ]);
    expect(pick?.row['name'], 'Biaya hidup');
    expect(mainBudget([budget('Jajan', 'week', 1), budget('Liburan', 'year', 9)])?.row['name'], 'Jajan');
    expect(mainBudget([]), null);
  });

  test('mainBudget: the picked budget wins while it exists', () {
    final all = [budget('Biaya hidup', 'month', 250000000), budget('Liburan', 'year', 1000000000)];
    expect(mainBudget(all, pickedId: 'Liburan')?.row['name'], 'Liburan');
    expect(mainBudget(all, pickedId: 'deleted')?.row['name'], 'Biaya hidup');
  });
}
