// Renders the README screenshots from made-up data, light and dark, into docs/readme/.
// Run: flutter test screenshots --update-goldens
// Kept out of test/ so CI never compares these images (fonts render differently on Linux).
import 'dart:convert';
import 'dart:io';

import 'package:cashflow_app/db.dart';
import 'package:cashflow_app/schema.dart';
import 'package:cashflow_app/screens/diagnosis_page.dart';
import 'package:cashflow_app/screens/home_page.dart';
import 'package:cashflow_app/screens/onboarding.dart';
import 'package:cashflow_app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:powersync/powersync.dart' show PowerSyncDatabase;
import 'package:supabase_flutter/supabase_flutter.dart';

const _user = 'demo-user';
final _now = DateTime.now();

Future<void> _loadFonts() async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final f in manifest) {
    final loader = FontLoader(f['family'] as String);
    for (final a in f['fonts'] as List) {
      loader.addFont(rootBundle.load(a['asset'] as String));
    }
    await loader.load();
  }
}

String _iso(DateTime d) => d.toUtc().toIso8601String();
String _day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
int _rp(int rupiah) => rupiah * 100;

/// A made-up month and a half of one person's money: no row comes from a real account.
Future<void> _seed() async {
  final now = _iso(_now);
  Future<void> row(String table, Map<String, Object?> v) => db.execute(
    'INSERT INTO $table (${v.keys.join(', ')}) VALUES (${List.filled(v.length, '?').join(', ')})',
    v.values.toList(),
  );

  final accounts = {
    'dompet': ('Dompet', 'cash', null, 650000),
    'bca': ('BCA', 'bank', 'bca', 6200000),
    'gopay': ('GoPay', 'ewallet', 'gopay', 300000),
    'tabungan': ('Tabungan', 'savings', 'jago', 9500000),
  };
  for (final MapEntry(key: id, value: a) in accounts.entries) {
    await row('accounts', {
      'id': id, 'user_id': _user, 'name': a.$1, 'type': a.$2, 'provider': a.$3, 'currency': 'IDR',
      'initial_balance': _rp(a.$4), 'archived': 0, 'exclude_from_stats': 0, 'created_at': now, 'updated_at': now,
    });
  }

  const categories = {
    'makan': ('Makan & Minum', 'expense', 'need'),
    'harian': ('Belanja Harian', 'expense', 'need'),
    'transport': ('Transportasi', 'expense', 'need'),
    'tagihan': ('Tagihan', 'expense', 'must'),
    'kos': ('Tempat Tinggal', 'expense', 'must'),
    'sehat': ('Kesehatan', 'expense', 'must'),
    'hiburan': ('Hiburan', 'expense', 'want'),
    'online': ('Belanja Online', 'expense', 'want'),
    'lainnya': ('Lainnya', 'expense', null),
    'gaji': ('Gaji', 'income', null),
    'masuk': ('Pemasukan Lain', 'income', null),
  };
  for (final MapEntry(key: id, value: c) in categories.entries) {
    await row('categories', {
      'id': id, 'user_id': _user, 'name': c.$1, 'type': c.$2, 'need_level': c.$3, 'keywords': '[]',
      'archived': 0, 'created_at': now, 'updated_at': now,
    });
  }

  var n = 0;
  Future<void> rec(int daysAgo, String type, int rupiah, String account, String? category, String note,
      {String? to, int hour = 12}) {
    final d = DateTime(_now.year, _now.month, _now.day - daysAgo, hour, (n * 7) % 60);
    return row('records', {
      'id': 'r${n++}', 'user_id': _user, 'account_id': account, 'type': type, 'amount': _rp(rupiah),
      'currency': 'IDR', 'category_id': category, 'transfer_account_id': to, 'transfer_amount': to == null ? null : _rp(rupiah),
      'label_ids': '[]', 'note': note, 'occurred_at': _iso(d), 'status': 'confirmed', 'source': 'manual',
      'exclude_from_budget': 0, 'created_at': now, 'updated_at': now,
    });
  }

  // The last 45 days, newest first.
  for (final month in [0, 1]) {
    final payday = _now.difference(DateTime(_now.year, _now.month - month, 1)).inDays;
    if (payday >= 0) {
      await rec(payday, 'income', 7500000, 'bca', 'gaji', 'Gaji bulanan', hour: 9);
      await rec(payday, 'expense', 1500000, 'bca', 'kos', 'Kos', hour: 10);
      await rec(payday, 'transfer', 1000000, 'bca', null, 'Sisihkan tabungan', to: 'tabungan', hour: 11);
    }
  }
  const daily = [
    ('makan', 'Nasi padang', 28000, 'dompet'),
    ('makan', 'Kopi susu', 22000, 'gopay'),
    ('transport', 'Ojek ke kantor', 18000, 'gopay'),
    ('makan', 'Makan siang', 35000, 'gopay'),
    ('harian', 'Belanja mingguan', 185000, 'bca'),
    ('transport', 'Bensin', 50000, 'dompet'),
    ('hiburan', 'Nonton bioskop', 60000, 'gopay'),
    ('makan', 'Martabak', 45000, 'dompet'),
    ('online', 'Kaus polos', 129000, 'bca'),
    ('tagihan', 'Pulsa & data', 100000, 'gopay'),
  ];
  for (var day = 0; day < 45; day++) {
    for (var i = 0; i < 2; i++) {
      final (cat, note, amount, account) = daily[(day * 3 + i * 5) % daily.length];
      await rec(day, 'expense', amount, account, cat, note, hour: 8 + i * 6 + day % 3);
    }
  }
  await rec(3, 'expense', 350000, 'bca', 'tagihan', 'Internet rumah', hour: 19);
  await rec(9, 'expense', 85000, 'dompet', 'sehat', 'Obat flu', hour: 20);
  await rec(12, 'income', 400000, 'bca', 'masuk', 'Jual barang bekas', hour: 15);
  await rec(1, 'transfer', 200000, 'bca', null, 'Isi saldo GoPay', to: 'gopay', hour: 7);

  final start = DateTime(_now.year, _now.month, 1);
  await row('budgets', {
    'id': 'b-bulanan', 'user_id': _user, 'name': 'Jatah bulanan', 'period': 'month', 'amount': _rp(4000000),
    'currency': 'IDR', 'start_date': _day(start),
    'category_ids': jsonEncode(['makan', 'harian', 'transport', 'hiburan', 'online']),
    'account_ids': '[]', 'label_ids': '[]', 'created_at': now, 'updated_at': now,
  });
  await row('goals', {
    'id': 'g-darurat', 'user_id': _user, 'name': 'Dana darurat', 'target_amount': _rp(20000000), 'currency': 'IDR',
    'account_id': 'tabungan', 'target_date': _day(DateTime(_now.year + 1, 6, 30)), 'state': 'active',
    'created_at': now, 'updated_at': now,
  });
  for (final (id, name, cat, amount, inDays) in [
    ('p-internet', 'Internet rumah', 'tagihan', 350000, 6),
    ('p-listrik', 'Token listrik', 'tagihan', 200000, 11),
  ]) {
    final due = DateTime(_now.year, _now.month, _now.day + inDays);
    await row('planned_payments', {
      'id': id, 'user_id': _user, 'name': name, 'account_id': 'bca', 'category_id': cat, 'type': 'expense',
      'amount': _rp(amount), 'currency': 'IDR', 'rrule': 'FREQ=MONTHLY;BYMONTHDAY=${due.day}',
      'next_due_date': _day(due), 'remind_days_before': 1, 'created_at': now, 'updated_at': now,
    });
  }
  await row('prefs', {'id': 'home_budget', 'value': 'b-bulanan'});
  // Nothing waits to upload, so the sync button shows no pending badge.
  for (var tx = await db.getNextCrudTransaction(); tx != null; tx = await db.getNextCrudTransaction()) {
    await tx.complete();
  }
}

/// Lets the database answer the screen's queries, then draws the result.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _show(WidgetTester tester, Widget page, Brightness brightness) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness),
      builder: (context, child) =>
          MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
      home: page,
    ),
  );
  await _settle(tester);
}

Future<void> _shoot(WidgetTester tester, String name, Brightness brightness) => expectLater(
  find.byType(MaterialApp),
  matchesGoldenFile('../docs/readme/$name-${brightness.name}.png'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('cashflow/notifications'),
    // Notification access on, so the screens don't show the "Aktifkan" card.
    (call) async => call.method == 'isEnabled',
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => Directory.systemTemp.path,
  );
  // Supabase keeps its sign-in state here; empty means signed out.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/shared_preferences'),
    (call) async => <String, Object>{},
  );

  setUpAll(() async {
    await _loadFonts();
    await initializeDateFormatting('id_ID');
    final dir = await Directory.systemTemp.createTemp('flowku-readme');
    db = PowerSyncDatabase(schema: schema, path: '${dir.path}/readme.db');
    await db.initialize();
    await _seed();
    // The header reads the signed-in user; nothing here reaches a server.
    await Supabase.initialize(
      url: 'http://localhost',
      publishableKey: 'readme',
      authOptions: const FlutterAuthClientOptions(localStorage: EmptyLocalStorage()),
    );
    // Diagnosis CFO shows stored advice instead of asking Gemini for it.
    final view = (await loadDiagnosis()).view!;
    await setPref(
      diagnosisAdviceKey,
      jsonEncode({
        'payload': view.payload,
        'at': _iso(_now),
        'advice': {
          'summary': 'Arus kasmu sehat: pemasukan menutup semua pengeluaran dan masih ada sisa untuk ditabung. '
              'Pos makan di luar paling cepat naik bulan ini.',
          'steps': [
            {'title': 'Batasi jajan kopi', 'why': 'Kopi dan camilan muncul hampir setiap hari, sekitar Rp600 ribu sebulan.'},
            {'title': 'Naikkan setoran dana darurat', 'why': 'Sisa bulan lalu cukup untuk menambah Rp500 ribu tanpa mengganggu jatah.'},
            {'title': 'Siapkan tagihan lebih awal', 'why': 'Internet dan listrik jatuh tempo dalam dua minggu ke depan.'},
          ],
        },
      }),
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('README screens ($brightness)', (tester) async {
      debugDisableShadows = false;
      await _show(tester, const HomePage(), brightness);
      await _shoot(tester, 'beranda', brightness);
      for (final (tab, name) in [('Transaksi', 'transaksi'), ('Rencana', 'rencana'), ('Laporan', 'laporan')]) {
        await tester.tap(find.text(tab).last);
        await _settle(tester);
        await _shoot(tester, name, brightness);
      }

      await _show(tester, const DiagnosisPage(), brightness);
      await _shoot(tester, 'diagnosis', brightness);

      await _show(tester, const WelcomePage(), brightness);
      await _shoot(tester, 'intro', brightness);

      await tester.pumpWidget(const SizedBox());
      debugDisableShadows = true;
    });
  }

  // Runs after the screens above, from the images they just wrote.
  for (final brightness in Brightness.values) {
    testWidgets('README hero ($brightness)', (tester) async {
      tester.view.physicalSize = const Size(1280 * 2, 640 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final shots = [
        for (final name in ['transaksi', 'beranda', 'laporan'])
          MemoryImage(File('docs/readme/$name-${brightness.name}.png').readAsBytesSync()),
      ];
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(brightness),
          home: _Hero(shots),
        ),
      );
      final context = tester.element(find.byType(_Hero));
      await tester.runAsync(() => Future.wait([for (final s in shots) precacheImage(s, context)]));
      await tester.pump();
      await expectLater(find.byType(_Hero), matchesGoldenFile('../docs/readme/hero-${brightness.name}.png'));
    });
  }
}

/// The README's banner: the name and what it does, beside three screens.
class _Hero extends StatelessWidget {
  const _Hero(this.shots);
  final List<ImageProvider> shots;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget phone(ImageProvider shot, double height) => Container(
      height: height,
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0F0D),
        borderRadius: BorderRadius.circular(height * 0.075),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height * 0.065),
        child: AspectRatio(aspectRatio: 390 / 844, child: Image(image: shot, fit: BoxFit.cover)),
      ),
    );
    Widget chip(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: AppText.label.copyWith(fontSize: 16, color: c.onPrimarySoft)),
    );
    return Material(
      color: c.bg,
      child: Stack(
        children: [
          Positioned(
            right: -40,
            top: 70,
            bottom: 70,
            width: 680,
            child: DecoratedBox(
              decoration: BoxDecoration(color: c.hero, borderRadius: BorderRadius.circular(48)),
            ),
          ),
          Positioned(
            left: 72,
            top: 0,
            bottom: 0,
            width: 400,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Flowku', style: AppText.title.copyWith(fontSize: 76, height: 1, color: c.ink)),
                const SizedBox(height: 20),
                Text(
                  'Track every rupiah in seconds. A personal finance app for Android that works offline.',
                  style: AppText.body.copyWith(fontSize: 24, height: 1.35, color: c.inkMuted),
                ),
                const SizedBox(height: 28),
                Wrap(spacing: 10, runSpacing: 10, children: [chip('Offline-first'), chip('AI capture'), chip('Open source')]),
              ],
            ),
          ),
          Positioned(
            right: 44,
            top: 0,
            bottom: 0,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                phone(shots[0], 440),
                const SizedBox(width: 20),
                phone(shots[1], 520),
                const SizedBox(width: 20),
                phone(shots[2], 440),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
