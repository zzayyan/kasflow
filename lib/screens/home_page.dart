import 'dart:async';

import 'package:flutter/material.dart';

import '../notifications.dart';
import '../theme.dart';
import 'bills_tab.dart';
import 'dashboard_tab.dart';
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
  late final Timer _notificationPoll;

  @override
  void initState() {
    super.initState();
    _reminders = keepRemindersScheduled();
    // Tabs import on resume; this catches a notification that arrives while the app stays open.
    _notificationPoll = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
      if (await notificationsWaiting()) await importNotifications();
    });
  }

  @override
  void dispose() {
    _notificationPoll.cancel();
    _reminders.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Every tab draws its own header, as in the design; Beranda's avatar opens Pengaturan.
      body: switch (_tab) {
        0 => DashboardTab(onOpenTab: (i) => setState(() => _tab = i)),
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
          onTap: () => onSelect(i), // excludeSemantics drops the InkWell's own action
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
