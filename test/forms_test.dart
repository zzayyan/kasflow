import 'package:cashflow_app/screens/bills_tab.dart';
import 'package:cashflow_app/screens/record_form.dart';
import 'package:cashflow_app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

// Form fields take a tap anywhere on their row or block, not only on the typed text.

const _accounts = [
  {'id': 'a1', 'name': 'BRI', 'currency': 'IDR', 'provider': null, 'balance': 0},
];
const _categories = [
  {'id': 'c1', 'name': 'Tagihan', 'type': 'expense', 'keywords': null, 'icon': null},
];

Future<void> _pump(WidgetTester tester, Widget body, Brightness brightness) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildAppTheme(brightness), home: body));
  await tester.pump();
}

bool _focused(WidgetTester tester, String hint) => tester
    .widget<TextField>(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint))
    .focusNode!
    .hasFocus;

void main() {
  setUpAll(() => initializeDateFormatting('id_ID'));

  for (final brightness in Brightness.values) {
    testWidgets('Catat: the amount block and note row focus their field ($brightness)', (tester) async {
      await _pump(tester, const RecordForm(accounts: _accounts, categories: _categories, labels: []), brightness);
      expect(_focused(tester, '0'), isFalse);
      await tester.tapAt(tester.getTopLeft(find.text('Nominal')) - const Offset(100, 0)); // far left of the label
      await tester.pump();
      expect(_focused(tester, '0'), isTrue);
      await tester.tap(find.text('Catatan')); // the small label, not the field
      await tester.pump();
      expect(_focused(tester, 'contoh: bakso, bensin, token PLN'), isTrue);
    });

    testWidgets('Tagihan sheet builds and its rows focus their fields ($brightness)', (tester) async {
      await _pump(tester, const Scaffold(body: BillForm(accounts: _accounts, categories: _categories)), brightness);
      expect(find.text('Tagihan baru'), findsOneWidget);
      expect(find.text('Bulanan'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.payments_outlined)); // the row's icon
      await tester.pump();
      expect(_focused(tester, '0'), isTrue);
    });
  }
}
