import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:powersync/powersync.dart' show SyncStatus;
import 'package:share_plus/share_plus.dart';

import '../app_lock.dart';
import '../db.dart';
import '../export_csv.dart';
import '../notifications.dart';
import '../recurrence.dart';
import '../theme.dart';
import '../ui.dart';
import 'accounts_tab.dart';
import 'bills_tab.dart';
import 'categories_page.dart';
import 'labels_page.dart';

// Pengaturan (gear on Beranda), after the "Usulan · Pengaturan" artboard: the data lists and this
// phone's preferences. Profil (avatar on Beranda, "Usulan · Profil" artboard) holds who is signed
// in, whether everything has reached the server, and logging out.

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with WidgetsBindingObserver {
  final _subs = <StreamSubscription<void>>[];
  Map<String, dynamic>? _counts;
  bool? _notifications;
  bool _hideBalance = false;
  (int, int) _reminder = (9, 0);

  void _set(VoidCallback change) {
    if (mounted) setState(change);
  }

  Future<void> _refreshNotifications() async {
    final enabled = await notificationAccessEnabled();
    _set(() => _notifications = enabled);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subs.addAll([
      db
          .watch('''
            SELECT (SELECT COUNT(*) FROM accounts WHERE archived = 0) AS accounts,
              (SELECT COUNT(*) FROM categories WHERE archived = 0) AS categories,
              (SELECT COUNT(*) FROM labels) AS labels''')
          .listen((rows) => _set(() => _counts = rows.first)),
    ]);
    unawaited(_refreshNotifications());
    unawaited(() async {
      final hide = await getPref('hide_balance');
      final time = await getPref('reminder_time');
      _set(() {
        _hideBalance = hide == '1';
        _reminder = parseReminderTime(time);
      });
    }());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    super.dispose();
  }

  // Back from Android's notification-access screen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshNotifications());
  }

  /// Turning the lock on or off asks for the fingerprint first, so nobody else can drop it.
  Future<void> _setLock(bool on) async {
    final ok = await confirmOwner(on ? 'Nyalakan kunci Cashflow' : 'Matikan kunci Cashflow');
    if (ok == null && mounted) showMessage(context, 'Pasang sidik jari atau kunci layar di pengaturan HP dulu.');
    if (ok != true) return; // cancelled: nothing to say
    haptic(Haptic.click);
    _set(() => appLockOn.value = on);
    await setPref('app_lock', on ? '1' : '0');
  }

  /// Every confirmed record as a CSV, handed to Android's share sheet (Drive, WhatsApp, Files...).
  Future<void> _export() async {
    final rows = await db.getAll('''
      SELECT r.occurred_at, r.type, r.amount, r.currency, a.name AS account, t.name AS target,
        c.name AS category, r.note,
        (SELECT group_concat('#' || l.name, ' ') FROM json_each(r.label_ids) j JOIN labels l ON l.id = j.value)
          AS labels
      FROM records r
      LEFT JOIN accounts a ON a.id = r.account_id
      LEFT JOIN accounts t ON t.id = r.transfer_account_id
      LEFT JOIN categories c ON c.id = r.category_id
      WHERE r.status = 'confirmed'
      ORDER BY julianday(r.occurred_at)''');
    if (!mounted) return;
    if (rows.isEmpty) return showMessage(context, 'Belum ada transaksi untuk diekspor.');
    final name = 'cashflow-transaksi-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.csv';
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(utf8.encode(recordsCsv(rows)), mimeType: 'text/csv')],
        fileNameOverrides: [name],
        subject: name,
      ),
    );
  }

  void _open(Widget page) => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));

  Future<void> _pickReminderTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _reminder.$1, minute: _reminder.$2),
    );
    if (picked == null) return;
    final value = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    await setPref('reminder_time', value); // the reminder watcher reschedules every bill
    _set(() => _reminder = (picked.hour, picked.minute));
  }

  static const _themeNames = {ThemeMode.light: 'Terang', ThemeMode.dark: 'Gelap', ThemeMode.system: 'Ikuti sistem'};

  Future<void> _pickTheme() async {
    final picked = await showModalBottomSheet<ThemeMode>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetTitle('Tema'),
            for (final MapEntry(key: mode, value: name) in _themeNames.entries)
              ListTile(
                title: Text(name),
                subtitle: mode == ThemeMode.system ? const Text('Terang atau gelap mengikuti pengaturan HP') : null,
                selected: mode == themeMode.value,
                trailing: mode == themeMode.value ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, mode),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    // setState too: Ikuti sistem on a light phone changes no color, so nothing else rebuilds this row.
    _set(() => themeMode.value = picked);
    await setPref('theme', picked.name);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final counts = _counts;
    String time((int, int) t) => '${t.$1.toString().padLeft(2, '0')}.${t.$2.toString().padLeft(2, '0')}';
    return Scaffold(
      appBar: pageAppBar(context, 'Pengaturan'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 28),
        children: [
          _Group('Data', [
            _Item(
              Icons.account_balance_wallet_outlined,
              'Akun',
              trailing: _Count(counts?['accounts']),
              onTap: () => _open(const AccountsPage()),
            ),
            _Item(
              Icons.grid_view,
              'Kategori',
              trailing: _Count(counts?['categories']),
              onTap: () => _open(const CategoriesPage()),
            ),
            _Item(Icons.sell_outlined, 'Label', trailing: _Count(counts?['labels']), onTap: () => _open(const LabelsPage())),
            _Item(
              Icons.notifications_none,
              'Catat dari notifikasi',
              trailing: _notifications == null
                  ? null
                  : Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: _notifications! ? c.primarySoft : c.surfaceMuted,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _notifications! ? 'Aktif' : 'Nonaktif',
                        style: AppText.caption.copyWith(
                          fontWeight: FontWeight.w600,
                          color: _notifications! ? c.primary : c.inkMuted,
                        ),
                      ),
                    ),
              onTap: openNotificationAccessSettings,
            ),
            _Item(Icons.ios_share, 'Ekspor transaksi', onTap: _export),
          ]),
          const SizedBox(height: AppSpace.section),
          _Group('Tampilan dan pengingat', [
            _Item(
              Icons.contrast,
              'Tema',
              trailing: Text(_themeNames[themeMode.value]!, style: AppText.label.copyWith(color: c.inkMuted)),
              onTap: _pickTheme,
            ),
            MergeSemantics(
              child: _Item(
                Icons.visibility_outlined,
                'Sembunyikan saldo saat dibuka',
                trailing: Switch(
                  value: _hideBalance,
                  onChanged: (on) {
                    setState(() => _hideBalance = on);
                    unawaited(setPref('hide_balance', on ? '1' : '0'));
                  },
                ),
              ),
            ),
            MergeSemantics(
              child: _Item(
                Icons.fingerprint,
                'Kunci dengan sidik jari',
                trailing: Switch(value: appLockOn.value, onChanged: _setLock),
              ),
            ),
            MergeSemantics(
              child: _Item(
                Icons.vibration,
                'Getar saat mengetuk',
                trailing: Switch(
                  value: hapticsOn.value,
                  onChanged: (on) {
                    setState(() => hapticsOn.value = on);
                    if (on) haptic(Haptic.tick); // a sample of what was just turned on
                    unawaited(setPref('haptics', on ? '1' : '0'));
                  },
                ),
              ),
            ),
            _Item(
              Icons.schedule,
              'Jam pengingat tagihan',
              trailing: Text(time(_reminder), style: AppText.label.copyWith(color: c.inkMuted)),
              onTap: _pickReminderTime,
            ),
            // ponytail: read-only until multi-currency ships (amounts are IDR cents everywhere).
            _Item(
              Icons.payments_outlined,
              'Mata uang utama',
              trailing: Text('IDR', style: AppText.label.copyWith(color: c.inkMuted)),
            ),
          ]),
        ],
      ),
    );
  }
}

/// Profil, the sheet behind the avatar on Beranda ("Usulan · Profil" artboard): who is signed in,
/// whether everything has reached the server, and logging out.
Future<void> showProfileSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: AppColors.of(context).surface,
  builder: (_) => const _ProfileSheet(),
);

class _ProfileSheet extends StatefulWidget {
  const _ProfileSheet();

  @override
  State<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<_ProfileSheet> {
  late final StreamSubscription<SyncStatus> _sub;
  SyncStatus _status = db.currentStatus;
  int _pending = 0; // changes on this phone not uploaded yet

  Future<void> _refreshPending() async {
    final stats = await db.getUploadQueueStats();
    if (mounted) setState(() => _pending = stats.count);
  }

  @override
  void initState() {
    super.initState();
    _sub = db.statusStream.listen((s) {
      if (mounted) setState(() => _status = s);
      unawaited(_refreshPending()); // the queue shrinks as uploads finish
    });
    unawaited(_refreshPending());
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }

  /// The name on Beranda and here, kept with the account so it follows the user to another phone.
  Future<void> _rename() async {
    final controller = TextEditingController(text: userDisplayName());
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nama panggilan'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'contoh: Zayyan', counterText: ''),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Simpan')),
        ],
      ),
    );
    // The controller is left to the GC: the dialog still uses it while it animates out.
    if (name == null || name == userDisplayName() || !mounted) return;
    if (name.isEmpty) return showMessage(context, 'Nama tidak boleh kosong.');
    if (!await setUserDisplayName(name)) {
      if (mounted) showMessage(context, 'Butuh internet untuk ganti nama. Coba lagi saat online.');
      return;
    }
    haptic(Haptic.click);
    if (mounted) setState(() {});
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keluar dari akun?'),
        content: const Text('Data di HP ini dihapus. Semuanya tetap tersimpan di server dan kembali saat kamu masuk lagi.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Keluar')),
        ],
      ),
    );
    if (ok != true) return;
    if (!await logout()) {
      if (mounted) showMessage(context, 'Masih ada data yang belum tersinkron. Sambungkan internet dulu, lalu coba lagi.');
      return;
    }
    await scheduleReminders(const []); // the next user on this phone must not get this user's bills
    // The app's root swaps to the login page; drop this sheet from above it.
    if (mounted) Navigator.popUntil(context, (route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final name = userDisplayName();
    final email = supabase.auth.currentUser?.email ?? '';
    final synced = _pending == 0;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 72,
                height: 72,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: c.hero, shape: BoxShape.circle),
                child: Text(name[0], style: AppText.title.copyWith(fontSize: 28, color: c.onHero)),
              ),
            ),
            const SizedBox(height: 12),
            // The pencil sits on the right of a centered name; the empty box on the left balances it.
            Row(
              children: [
                const SizedBox(width: 40),
                Expanded(
                  child: Text(
                    name,
                    textAlign: TextAlign.center,
                    style: AppText.heading.copyWith(fontSize: 20),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Ganti nama',
                  onPressed: _rename,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.edit_outlined, size: 18, color: c.inkMuted),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              email,
              textAlign: TextAlign.center,
              style: AppText.label.copyWith(color: c.inkMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 18),
            _SyncCard(status: _status, pending: _pending, onRetry: reconnect),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: synced ? _logout : null,
              icon: const Icon(Icons.logout, size: 20),
              label: const Text('Keluar'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
                backgroundColor: c.bg,
                foregroundColor: c.alert,
                disabledBackgroundColor: c.bg,
                disabledForegroundColor: c.inkMuted,
                textStyle: AppText.bodyStrong,
              ),
            ),
            if (!synced) ...[
              const SizedBox(height: AppSpace.tight),
              Text(
                'Bisa keluar setelah semua data tersinkron, supaya tidak ada transaksi yang hilang.',
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: c.inkMuted, height: 1.4),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Synced, syncing, or waiting: what reached the server, said in words with an icon.
class _SyncCard extends StatelessWidget {
  const _SyncCard({required this.status, required this.pending, required this.onRetry});

  final SyncStatus status;
  final int pending;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final busy = status.connected && (status.uploading || status.downloading);
    final done = status.connected && !busy && pending == 0;
    final last = status.lastSyncedAt?.toLocal();
    final changes = pending == 1 ? '1 perubahan' : '$pending perubahan';
    final (icon, title, detail) = done
        ? (
            Icons.cloud_done_outlined,
            'Semua data tersinkron',
            last == null ? null : 'Terakhir ${_when(last)}',
          )
        : busy
        ? (Icons.cloud_sync_outlined, pending > 0 ? 'Menyinkronkan $changes' : 'Menyinkronkan', 'Sebentar lagi selesai.')
        : (
            Icons.cloud_off_outlined,
            pending > 0 ? '$changes belum tersinkron' : 'Belum tersambung ke server',
            'Kamu sedang offline. Datanya aman di HP ini dan terkirim otomatis saat online.',
          );
    final waiting = !done && !busy;
    return Container(
      padding: const EdgeInsets.all(AppSpace.card),
      decoration: BoxDecoration(
        color: waiting ? c.surfaceMuted : c.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle),
                child: Icon(icon, size: 22, color: waiting ? c.ink : c.primary),
              ),
              const SizedBox(width: AppSpace.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppText.bodyStrong),
                    if (detail != null) ...[
                      const SizedBox(height: 3),
                      Text(detail, style: AppText.label.copyWith(color: c.onPrimarySoft, height: 1.4)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (waiting) ...[
            const SizedBox(height: AppSpace.gap),
            FilledButton(
              onPressed: onRetry,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44), textStyle: AppText.label),
              child: const Text('Coba sinkron sekarang'),
            ),
          ],
        ],
      ),
    );
  }

  static String _when(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final clock = DateFormat('HH.mm').format(t);
    return switch (today.difference(day).inDays) {
      0 => 'hari ini, $clock',
      1 => 'kemarin, $clock',
      _ => '${DateFormat('d MMM', 'id_ID').format(t)}, $clock',
    };
  }
}

class _Group extends StatelessWidget {
  const _Group(this.title, this.items);

  final String title;
  final List<Widget> items;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(title, style: AppText.label.copyWith(color: c.inkMuted)),
        ),
        Material(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                for (final (i, item) in items.indexed) ...[
                  if (i > 0) const Divider(indent: 16, endIndent: 16),
                  item,
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Item extends StatelessWidget {
  const _Item(this.icon, this.label, {this.trailing, this.onTap});

  final IconData icon;
  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSpace.rowMin),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(icon, size: 22, color: c.ink),
              const SizedBox(width: AppSpace.gap),
              Expanded(child: Text(label, style: AppText.body)),
              ?trailing,
              if (onTap != null) ...[const SizedBox(width: 8), Icon(Icons.chevron_right, size: 18, color: c.inkMuted)],
            ],
          ),
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.n);

  final Object? n;

  @override
  Widget build(BuildContext context) =>
      Text(n == null ? '' : '$n', style: AppText.label.copyWith(color: AppColors.of(context).inkMuted));
}
