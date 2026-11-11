import 'package:cashflow_app/screens/login_page.dart';
import 'package:cashflow_app/screens/onboarding.dart';
import 'package:cashflow_app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// The signed-out screens can't be opened on a signed-in phone, so they are built here at the
// design's phone size, light and dark. Overflow or a build error fails the test.

Future<void> _pump(WidgetTester tester, Widget page, Brightness brightness) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildAppTheme(brightness), home: page));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The intro asks Android whether notification access is on; here it is off.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('cashflow/notifications'),
    (call) async => false,
  );

  for (final brightness in Brightness.values) {
    testWidgets('Intro pages swipe and step ($brightness)', (tester) async {
      await _pump(tester, const WelcomePage(), brightness);
      expect(find.text('Mulai'), findsOneWidget);
      await tester.drag(find.byType(PageView), const Offset(-300, 0)); // swipe to page 2
      await tester.pumpAndSettle();
      expect(find.text('Catat otomatis dari notifikasi bank'), findsOneWidget);
      await tester.tap(find.text('Lewati'));
      await tester.pumpAndSettle();
      expect(find.text('Daftar, 1 akun'), findsOneWidget);
      await tester.tap(find.text('GoPay'));
      await tester.pump();
      expect(find.text('Daftar, 2 akun'), findsOneWidget);
    });

    testWidgets('Lewati on the first page lands on the accounts page ($brightness)', (tester) async {
      await _pump(tester, const WelcomePage(), brightness);
      await tester.tap(find.text('Lewati'));
      await tester.pumpAndSettle();
      expect(find.text('Uangmu disimpan di mana saja?'), findsOneWidget);
    });

    testWidgets('Login and Daftar build ($brightness)', (tester) async {
      await _pump(tester, const LoginPage(), brightness);
      expect(find.text('Selamat datang lagi'), findsOneWidget);
      await tester.tap(find.text('Daftar').first);
      await tester.pump();
      expect(find.text('Nama panggilan (opsional)'), findsOneWidget);
    });
  }
}
