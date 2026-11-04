import 'dart:async';

import 'package:flutter/material.dart';

import '../db.dart';
import '../ui.dart';
import 'bills_tab.dart';
import 'categories_page.dart';
import 'dashboard_tab.dart';
import 'labels_page.dart';
import 'plans_tab.dart';
import 'record_form.dart';
import 'records_tab.dart';
import 'report_tab.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  late final StreamSubscription<void> _reminders;
  final _dueBills = watchDueBillCount();

  @override
  void initState() {
    super.initState();
    _reminders = keepRemindersScheduled();
  }

  @override
  void dispose() {
    _reminders.cancel();
    super.dispose();
  }

  Future<void> _logout() async {
    if (!await logout()) {
      if (mounted) {
        showMessage(context, 'Masih ada data yang belum tersinkron. Sambungkan internet dulu, lalu coba lagi.');
      }
      return;
    }
    await scheduleReminders(const []); // the next user on this phone must not get this user's bills
  }

  // The app menu. Beranda opens it from the avatar ([child]); other tabs from the app bar.
  Widget _menu(BuildContext context, {Widget? child}) => PopupMenuButton<String>(
    tooltip: 'Menu',
    onSelected: (choice) => switch (choice) {
      'categories' => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const CategoriesPage())),
      'labels' => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const LabelsPage())),
      _ => _logout(),
    },
    itemBuilder: (context) => const [
      PopupMenuItem(
        value: 'categories',
        child: ListTile(leading: Icon(Icons.category_outlined), title: Text('Kelola kategori')),
      ),
      PopupMenuItem(
        value: 'labels',
        child: ListTile(leading: Icon(Icons.sell_outlined), title: Text('Kelola label')),
      ),
      PopupMenuItem(
        value: 'logout',
        child: ListTile(leading: Icon(Icons.logout), title: Text('Keluar')),
      ),
    ],
    child: child,
  );

  // Sync status and the menu, in the app bar of every tab but Beranda.
  List<Widget> _actions(BuildContext context) => [
    StreamBuilder(
      stream: db.statusStream,
      initialData: db.currentStatus, // the stream only reports changes
      builder: (context, snap) {
        final s = snap.data;
        final (icon, label) = s == null || !s.connected
            ? (Icons.cloud_off, 'Offline: data aman di HP, sync saat online')
            : (s.uploading || s.downloading)
            ? (Icons.cloud_sync, 'Menyinkronkan')
            : (Icons.cloud_done, 'Tersinkron');
        return IconButton(icon: Icon(icon), tooltip: label, onPressed: () => showMessage(context, label));
      },
    ),
    _menu(context),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Beranda draws its own header (greeting, sync, menu), as in the design.
      appBar: _tab == 0
          ? null
          : AppBar(
              title: Text(const ['Beranda', 'Transaksi', 'Tagihan', 'Rencana', 'Laporan'][_tab]),
              actions: _actions(context),
            ),
      body: switch (_tab) {
        0 => DashboardTab(
          menu: (child) => _menu(context, child: child),
          onOpenTab: (i) => setState(() => _tab = i),
        ),
        1 => const RecordsTab(),
        2 => const BillsTab(),
        3 => const PlansTab(),
        _ => const ReportTab(),
      },
      floatingActionButton: _tab == 4
          ? null // the report has nothing to add
          : FloatingActionButton(
              onPressed: () => [showRecordForm, showRecordForm, showBillForm, showPlanChooser][_tab](context),
              child: const Icon(Icons.add),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Beranda',
          ),
          const NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Transaksi'),
          NavigationDestination(
            icon: StreamBuilder(
              stream: _dueBills,
              builder: (context, snap) => Badge(
                isLabelVisible: (snap.data ?? 0) > 0,
                label: Text('${snap.data}'),
                child: const Icon(Icons.event_repeat),
              ),
            ),
            label: 'Tagihan',
          ),
          const NavigationDestination(icon: Icon(Icons.savings_outlined), label: 'Rencana'),
          const NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Laporan'),
        ],
      ),
    );
  }
}
