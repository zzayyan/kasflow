import 'package:cashflow_app/screens/login_page.dart';
import 'package:cashflow_app/screens/onboarding.dart';
import 'package:cashflow_app/theme.dart';
import 'package:flutter/material.dart';
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
  for (final brightness in Brightness.values) {
    testWidgets('Welcome builds ($brightness)', (tester) async {
      await _pump(tester, const WelcomePage(), brightness);
      expect(find.text('Mulai'), findsOneWidget);
    });

    testWidgets('Login and Daftar build ($brightness)', (tester) async {
      await _pump(tester, const LoginPage(), brightness);
      expect(find.text('Selamat datang lagi'), findsOneWidget);
      await tester.tap(find.text('Daftar').first);
      await tester.pump();
      expect(find.text('Nama panggilan'), findsOneWidget);
    });

    testWidgets('Onboarding steps 2 and 3 build ($brightness)', (tester) async {
      await _pump(tester, const OnboardingFlow(), brightness);
      expect(find.text('Izinkan akses notifikasi'), findsOneWidget);
      await tester.tap(find.text('Nanti saja'));
      await tester.pump();
      expect(find.text('Selesai, 1 akun'), findsOneWidget);
      await tester.tap(find.text('GoPay'));
      await tester.pump();
      expect(find.text('Selesai, 2 akun'), findsOneWidget);
    });
  }
}
