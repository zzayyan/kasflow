import 'package:cashflow_app/theme.dart';
import 'package:cashflow_app/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

void main() {
  setUpAll(() => initializeDateFormatting('id_ID'));

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

  test('percentOf keeps a tiny share visible', () {
    expect(percentOf(1, 1000), '<1%');
    expect(percentOf(0, 1000), '0%');
    expect(percentOf(5, 1000), '1%');
    expect(percentOf(1, 0), '0%');
  });

  testWidgets('a finger sliding across the bars previews each and selects where it lifts', (tester) async {
    final picked = <int>[];
    final ticks = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('cashflow/notifications'), (call) async {
      if (call.method == 'haptic') ticks.add(call.arguments as String);
      return null;
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: SelectableBars(
              values: const [1, 2, 3, 4, 5, 6],
              labels: const ['a', 'b', 'c', 'd', 'e', 'f'],
              readouts: const ['a', 'b', 'c', 'd', 'e', 'f'],
              selected: 5,
              onSelect: picked.add,
              valueText: (v) => '$v',
            ),
          ),
        ),
      ),
    );
    final plot = tester.getRect(find.byType(GestureDetector).first);
    final gesture = await tester.startGesture(plot.centerRight - const Offset(5, 0));
    await gesture.moveBy(const Offset(-120, 0)); // past the drag slop, onto the middle columns
    await tester.pump();
    await gesture.moveBy(const Offset(-130, 0)); // to the first column
    await tester.pump();
    expect(picked, isEmpty); // a preview, not yet a pick
    await gesture.up();
    await tester.pump();
    expect(picked, [0]);
    expect(ticks, isNotEmpty);
    expect(ticks.toSet(), {'tick'});
  });

  for (final brightness in Brightness.values) {
    testWidgets('pickMonth lists 24 months, newest first, and returns the one tapped ($brightness)', (tester) async {
      DateTime? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked = await pickMonth(context, null),
              child: const Text('buka'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('buka'));
      await tester.pumpAndSettle();
      expect(find.text('Pilih bulan'), findsOneWidget);
      final now = DateTime.now();
      final names = [for (var i = 0; i < 24; i++) DateFormat('MMMM yyyy', 'id_ID').format(DateTime(now.year, now.month - i))];
      final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
      expect(tiles.length, lessThanOrEqualTo(24)); // the list scrolls, so only the first rows are built
      for (var i = 0; i < tiles.length; i++) {
        expect((tiles[i].title! as Text).data, names[i]);
      }
      await tester.tap(find.text(names[1]));
      await tester.pumpAndSettle();
      expect(picked, DateTime(now.year, now.month - 1));
    });
  }
}
