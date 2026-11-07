import 'package:cashflow_app/receipt_items.dart';
import 'package:cashflow_app/screens/accounts_tab.dart';
import 'package:cashflow_app/screens/bills_tab.dart';
import 'package:cashflow_app/screens/plans_tab.dart';
import 'package:cashflow_app/screens/record_form.dart';
import 'package:cashflow_app/theme.dart';
import 'package:cashflow_app/ui.dart';
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

    testWidgets('Catat: typing a note offers earlier notes, and picking one fills it ($brightness)', (tester) async {
      await _pump(
        tester,
        const RecordForm(accounts: _accounts, categories: _categories, labels: [], notes: ['Ayam Goreng', 'Bakso']),
        brightness,
      );
      await tester.tap(find.text('Catatan'));
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'contoh: bakso, bensin, token PLN'), 'ay');
      await tester.pumpAndSettle();
      expect(find.text('Ayam Goreng'), findsOneWidget);
      expect(find.text('Bakso'), findsNothing);
      await tester.tap(find.text('Ayam Goreng'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Ayam Goreng'), findsOneWidget);
    });

    // Issue #1: picking a category put the keyboard back over the form.
    testWidgets('Catat: picking a category from the list hides the keyboard ($brightness)', (tester) async {
      await _pump(tester, const RecordForm(accounts: _accounts, categories: _categories, labels: []), brightness);
      await tester.tap(find.text('Catatan'));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.text('Pilih kategori'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(ListTile), matching: find.text('Tagihan')));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
    });

    // chooseOne itself drops focus, so every picker sheet (here Akun) keeps the keyboard down.
    testWidgets('Catat: picking an account hides the keyboard ($brightness)', (tester) async {
      await _pump(tester, const RecordForm(accounts: _accounts, categories: _categories, labels: []), brightness);
      await tester.tap(find.text('Catatan'));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.text('BRI'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(ListTile), matching: find.text('BRI')));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('Catat: a tap on empty form space or a drag hides the keyboard ($brightness)', (tester) async {
      await _pump(tester, const RecordForm(accounts: _accounts, categories: _categories, labels: []), brightness);
      await tester.tap(find.text('Catatan'));
      await tester.pump();
      await tester.tap(find.text('Kategori lain')); // a plain label
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.text('Catatan'));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.drag(find.byType(ListView).first, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('Catat: picking a category chip hides the keyboard ($brightness)', (tester) async {
      await _pump(tester, const RecordForm(accounts: _accounts, categories: _categories, labels: []), brightness);
      await tester.tap(find.text('Catatan'));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      final chip = find.widgetWithText(ChoiceChip, 'Tagihan');
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('Catat: a receipt shows its lines, the gap to the total, and lines can be fixed ($brightness)', (tester) async {
      const items = [
        ReceiptItem(name: 'Ayam Tangkap Dada', qty: 1, amount: 2310000),
        ReceiptItem(name: 'Nasi Putih', qty: 2, amount: 1320000),
        ReceiptItem(name: 'Tempe Goreng', qty: 1, amount: 660000),
        ReceiptItem(name: 'Teh Tarik Dingin', qty: 1, amount: 3300000),
        ReceiptItem(name: 'Kerupuk', qty: 1, amount: 200000),
      ]; // 77.900, against a total of 85.690: 7.790 of tax
      await _pump(
        tester,
        const RecordForm(
          accounts: _accounts,
          categories: _categories,
          labels: [],
          prefill: Prefill(amount: 8569000, note: 'Ramlah', items: items),
        ),
        brightness,
      );
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Rincian item · 5 item'), 300, scrollable: list);
      expect(find.text('Ayam Tangkap Dada'), findsOneWidget);
      expect(find.text('2 ×'), findsOneWidget);
      expect(find.text('Kerupuk'), findsNothing); // a long receipt starts folded
      await tester.scrollUntilVisible(find.text('Selisih dari total'), 300, scrollable: list);
      expect(find.text('+Rp 7.790'), findsOneWidget);
      await tester.ensureVisible(find.text('Lihat semua 5 item'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lihat semua 5 item'));
      await tester.pump();
      await tester.ensureVisible(find.text('Kerupuk'));
      await tester.pumpAndSettle();

      // Fix a name, then drop a line.
      await tester.tap(find.text('Kerupuk'));
      await tester.pumpAndSettle();
      expect(find.text('Ubah item'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Kerupuk'), 'Kerupuk Udang');
      await tester.tap(find.text('Simpan').last);
      await tester.pumpAndSettle();
      expect(find.text('Kerupuk Udang'), findsOneWidget);
      await tester.ensureVisible(find.text('Kerupuk Udang'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kerupuk Udang'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hapus'));
      await tester.pumpAndSettle();
      expect(find.text('Kerupuk Udang'), findsNothing);
      expect(find.text('Rincian item · 4 item'), findsOneWidget);
    });

    testWidgets('Catat: a record without a receipt has no Rincian item ($brightness)', (tester) async {
      await _pump(tester, const RecordForm(accounts: _accounts, categories: _categories, labels: []), brightness);
      expect(find.textContaining('Rincian item'), findsNothing);
    });

    testWidgets('Tagihan sheet builds and its rows focus their fields ($brightness)', (tester) async {
      await _pump(tester, const Scaffold(body: BillForm(accounts: _accounts, categories: _categories)), brightness);
      expect(find.text('Tagihan baru'), findsOneWidget);
      expect(find.text('Bulanan'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.payments_outlined)); // the row's icon
      await tester.pump();
      expect(_focused(tester, '0'), isTrue);
    });

    // Each sheet: its title shows, and tapping a money row's label puts the cursor in its field.
    for (final (sheet, title, money) in [
      (const GoalForm(accounts: _accounts), 'Goal tabungan baru', 'Target'),
      (const BudgetForm(categories: _categories, labels: []), 'Budget baru', 'Batas pengeluaran'),
      (const AccountForm(), 'Akun baru', 'Saldo awal'),
    ]) {
      testWidgets('$title sheet builds and its money row focuses ($brightness)', (tester) async {
        await _pump(tester, Scaffold(body: sheet), brightness);
        expect(find.text(title), findsOneWidget);
        await tester.tap(find.text(money));
        await tester.pump();
        final row = find.ancestor(of: find.text(money), matching: find.byType(FormRow));
        final field = tester.widget<TextField>(find.descendant(of: row, matching: find.byType(TextField)));
        expect(field.focusNode!.hasFocus, isTrue);
      });
    }
  }
}
