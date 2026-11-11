import 'package:cashflow_app/screens/login_page.dart';
import 'package:cashflow_app/screens/onboarding.dart';
import 'package:cashflow_app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// The signed-out screens can't be opened on a signed-in phone, so they are built here at the
// design's phone size, light and dark. Overflow or a build error fails the test.

/// With [animate] off, as with Android's "remove animations", the intro's looping demos stand still,
/// so pumpAndSettle can settle.
Future<void> _pump(WidgetTester tester, Widget page, Brightness brightness, {bool animate = false}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness),
      builder: (context, child) =>
          MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: !animate), child: child!),
      home: page,
    ),
  );
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
      // Access off here: both steps show on the one screen, the first asking for Cashflow's access.
      expect(find.textContaining('di daftar Akses notifikasi'), findsOneWidget);
      expect(find.textContaining('Pastikan notifikasi transaksi'), findsOneWidget);
      await tester.tap(find.text('Lewati'));
      await tester.pumpAndSettle();
      expect(find.text('Daftar, 1 akun'), findsOneWidget);
      await tester.tap(find.text('GoPay'));
      await tester.pump();
      expect(find.text('Daftar, 2 akun'), findsOneWidget);
    });

    testWidgets('Intro demos play through their loops ($brightness)', (tester) async {
      await _pump(tester, const WelcomePage(), brightness, animate: true);
      // Page 1 types three lines, one every five seconds, and the balance follows. By 20 s the first
      // line is fully typed again.
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('kopi 18rb pakai gopay'), findsOneWidget); // back to the first line
      await tester.tap(find.text('Mulai'));
      // Page 2's record is checked from 2.8 s into its loop.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('Tersimpan'), findsOneWidget);
      await tester.pumpWidget(const SizedBox()); // stops the loops before the test ends
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
