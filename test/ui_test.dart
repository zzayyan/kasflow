import 'package:cashflow_app/theme.dart';
import 'package:cashflow_app/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
