import 'package:cashflow_app/theme.dart';
import 'package:cashflow_app/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AmountInputFormatter', () {
    const f = AmountInputFormatter();
    TextEditingValue type(String old, String text, int cursor) => f.formatEditUpdate(
      TextEditingValue(text: old),
      TextEditingValue(text: text, selection: TextSelection.collapsed(offset: cursor)),
    );

    test('groups thousands as typed, cursor at the end', () {
      expect(type('500', '5000', 4).text, '5.000');
      expect(type('300.000', '300.0000', 8).text, '3.000.000');
      expect(type('3.000.000', '3.000.000', 9).selection.end, 9);
    });

    test('keeps minus and up to two decimals, drops other characters', () {
      expect(type('', '-500000', 7).text, '-500.000');
      expect(type('2', '2,567', 5).text, '2,56');
      expect(type('', 'Rp 25rb', 7).text, '25');
      expect(type('', '007', 3).text, '7');
    });

    test('keeps the cursor beside the same digit', () {
      // "1|.000" typing 2 -> "12|.000"
      final v = type('1.000', '12.000', 2);
      expect(v.text, '12.000');
      expect(v.selection.end, 2);
    });

    test('backspace after a dot deletes the digit before it', () {
      // "12.|000" backspace -> "1|.000"
      final v = type('12.000', '12000', 2);
      expect(v.text, '1.000');
      expect(v.selection.end, 1);
    });
  });

  Future<void> showBar(WidgetTester tester, {bool screenReader = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(accessibleNavigation: screenReader),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDone(context, 'Tersimpan', 'Makan · Rp 25.000', onUndo: () {}),
              child: const Text('simpan'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('simpan'));
    await tester.pump();
  }

  testWidgets('"Tersimpan" closes itself once its ring runs out', (tester) async {
    await showBar(tester);
    await tester.pump(undoTime - const Duration(milliseconds: 500));
    expect(find.text('Batalkan'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('Batalkan'), findsNothing);
  });

  testWidgets('with a screen reader, it waits for the user and shows no ring', (tester) async {
    await showBar(tester, screenReader: true);
    await tester.pump(undoTime * 3);
    expect(find.text('Batalkan'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
