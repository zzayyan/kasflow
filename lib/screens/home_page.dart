import 'dart:async';

import 'package:flutter/material.dart';

import '../db.dart';
import '../theme.dart';
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
      // Beranda, Transaksi and Rencana draw their own header, as in the design; the menu sits on
      // Beranda's avatar. Laporan keeps an app bar until its screen is redone.
      appBar: _tab < 3 ? null : AppBar(title: const Text('Laporan'), actions: _actions(context)),
      body: switch (_tab) {
        0 => DashboardTab(
          menu: (child) => _menu(context, child: child),
          onOpenTab: (i) => setState(() => _tab = i),
        ),
        1 => const RecordsTab(),
        2 => const PlansTab(),
        _ => const ReportTab(),
      },
      bottomNavigationBar: StreamBuilder(
        stream: _dueBills,
        builder: (context, snap) => _BottomNav(
          selected: _tab,
          dueBills: snap.data ?? 0,
          onSelect: (i) => setState(() => _tab = i),
          onAdd: () => showRecordForm(context),
        ),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.selected, required this.dueBills, required this.onSelect, required this.onAdd});

  final int selected;
  final int dueBills; // bills due soon or late, shown on Rencana
  final ValueChanged<int> onSelect;
  final VoidCallback onAdd; // the + in the middle: always records a transaction

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget item(int i, IconData icon, IconData selectedIcon, String label, {int badge = 0}) {
      final on = selected == i;
      return Expanded(
        child: Semantics(
          selected: on,
          button: true,
          label: badge > 0 ? '$label, $badge tagihan perlu dibayar' : label,
          excludeSemantics: true,
          child: InkWell(
            onTap: () => onSelect(i),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Badge(
                  isLabelVisible: badge > 0,
                  backgroundColor: c.alert,
                  textColor: c.onAlert,
                  label: Text('$badge'),
                  child: Icon(on ? selectedIcon : icon, color: on ? c.ink : c.inkMuted),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: AppText.caption.copyWith(
                    color: on ? c.ink : c.inkMuted,
                    fontWeight: on ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final dark = Theme.of(context).brightness == Brightness.dark;
    // Inside the bar, its top flush with the bar's top edge (84 tall with 6 below, as drawn).
    final add = Expanded(
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: c.primary,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: dark ? Colors.black.withValues(alpha: 0.5) : c.primary.withValues(alpha: 0.3),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onAdd,
              child: Tooltip(
                message: 'Catat transaksi',
                child: Icon(Icons.add, size: 28, color: c.onPrimary),
              ),
            ),
          ),
        ),
      ),
    );

    return Material(
      color: c.surface,
      child: SafeArea(
        top: false,
        child: Container(
          height: 84,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: c.surfaceMuted))),
          child: Row(
            children: [
              item(0, Icons.home_outlined, Icons.home, 'Beranda'),
              item(1, Icons.format_list_bulleted, Icons.format_list_bulleted, 'Transaksi'),
              add,
              item(2, Icons.track_changes_outlined, Icons.track_changes, 'Rencana', badge: dueBills),
              item(3, Icons.bar_chart_outlined, Icons.bar_chart, 'Laporan'),
            ],
          ),
        ),
      ),
    );
  }
}
