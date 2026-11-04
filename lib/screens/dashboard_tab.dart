import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:powersync/powersync.dart' show SyncStatus;

import '../db.dart';
import '../money.dart';
import '../notifications.dart';
import '../reports.dart';
import '../theme.dart';
import '../ui.dart';
import 'accounts_tab.dart';
import 'bills_tab.dart';
import 'record_form.dart';
import 'records_tab.dart';
import 'settings_page.dart';

// Beranda, after the "E · Beranda" and "Kosong · Beranda" artboards of the Cashflow UI/UX canvas.
// Until the first record exists it shows a getting-started checklist instead of the latest records.

final _digits = NumberFormat.decimalPattern('id_ID');
final _compact = NumberFormat.compact(locale: 'id_ID');

class DashboardTab extends StatefulWidget {
  const DashboardTab({super.key, required this.onOpenTab});

  /// Switches the bottom navigation: 1 Transaksi, 3 Laporan.
  final ValueChanged<int> onOpenTab;

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> with WidgetsBindingObserver {
  // Query results live in fields, kept fresh by one subscription per query. db.watch streams can
  // be listened to once only, and sections here come and go (new user, inbox), so no StreamBuilder.
  final _subs = <StreamSubscription<void>>[];
  StreamSubscription<void>? _monthSub;
  List<Map<String, dynamic>>? _recent;
  Map<String, dynamic>? _accounts; // `n`, `total`
  List<Map<String, dynamic>> _inbox = const []; // `provider`, `n`
  int _bills = 0;
  int? _net;

  StreamSubscription<void> _watch(String sql, void Function(List<Map<String, dynamic>> rows) onRows, [
    List<Object?> parameters = const [],
  ]) => db.watch(sql, parameters: parameters).listen((rows) {
    if (mounted) setState(() => onRows(rows));
  });

  // Same rules as the Laporan tab: confirmed records on accounts that count towards statistics.
  static const _monthSql = '''
    SELECT
      COALESCE(SUM(CASE WHEN r.type = 'income' THEN r.amount END), 0)
        - COALESCE(SUM(CASE WHEN r.type = 'expense' THEN r.amount END), 0) AS net
    FROM records r JOIN accounts a ON a.id = r.account_id
    WHERE r.status = 'confirmed' AND a.exclude_from_stats = 0 AND r.type IN ('income', 'expense')
      AND julianday(r.occurred_at) >= julianday(?1) AND julianday(r.occurred_at) < julianday(?2)''';

  late DateTime _month;
  bool _hidden = false; // starts from Pengaturan's 'Sembunyikan saldo saat dibuka'
  bool _notifications = false;

  void _watchMonth() {
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    final (start, end) = periodRange('month', now);
    unawaited(_monthSub?.cancel());
    _monthSub = _watch(_monthSql, (rows) => _net = rows.first['net'] as int, [utcIso(start), utcIso(end)]);
  }

  @override
  void initState() {
    super.initState();
    _subs.addAll([
      _watch('''
        SELECT r.*, a.name AS account_name, t.name AS target_name, c.name AS category_name, c.icon AS category_icon
        FROM records r
        LEFT JOIN accounts a ON a.id = r.account_id
        LEFT JOIN accounts t ON t.id = r.transfer_account_id
        LEFT JOIN categories c ON c.id = r.category_id
        ORDER BY julianday(r.occurred_at) DESC LIMIT 4''', (rows) => _recent = rows),
      _watch('''
        SELECT COUNT(*) AS n, COALESCE(SUM(b.balance), 0) AS total
        FROM accounts a JOIN ($accountBalancesSql) b ON b.id = a.id
        WHERE a.archived = 0''', (rows) => _accounts = rows.first),
      _watch('SELECT provider, COUNT(*) AS n FROM inbox GROUP BY provider', (rows) => _inbox = rows),
      _watch('SELECT COUNT(*) AS n FROM planned_payments', (rows) => _bills = rows.first['n'] as int),
    ]);
    _watchMonth();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_importInbox());
    unawaited(getPref('hide_balance').then((v) => v == '1' ? _set(() => _hidden = true) : null));
  }

  void _set(VoidCallback change) {
    if (mounted) setState(change);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in [..._subs, ?_monthSub]) {
      unawaited(s.cancel());
    }
    super.dispose();
  }

  // Beranda is the first screen, so it picks up new bank notifications too (the Transaksi tab
  // does the same). Coming back from the settings screen also ticks the checklist step.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_importInbox());
    final now = DateTime.now();
    if (now.year != _month.year || now.month != _month.month) setState(_watchMonth);
  }

  Future<void> _importInbox() async {
    final enabled = await notificationAccessEnabled();
    if (mounted && enabled != _notifications) setState(() => _notifications = enabled);
    if (enabled) await importNotifications();
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: AppSpace.section);
    final recent = _recent;
    final accounts = _accounts;
    final isNew = recent?.isEmpty ?? false;
    final accountCount = accounts?['n'] as int? ?? 0;
    final inboxCount = _inbox.fold<int>(0, (sum, r) => sum + (r['n'] as int));
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Theme.of(context).brightness == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: SafeArea(
        bottom: false,
        child: recent == null || accounts == null
            ? const SizedBox.shrink()
            : ListView(
                padding: const EdgeInsets.fromLTRB(AppSpace.page, 16, AppSpace.page, 24),
                children: [
                  _Header(
                    isNew: isNew,
                    onAvatar: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
                    ),
                  ),
                  gap,
                  _BalanceCard(
                    total: accounts['total'] as int,
                    net: isNew ? null : _net,
                    caption: isNew ? 'Total saldo · $accountCount akun' : 'Total saldo',
                    hidden: _hidden,
                    onToggleHidden: isNew ? null : () => setState(() => _hidden = !_hidden),
                    onReport: isNew ? null : () => widget.onOpenTab(3),
                  ),
                  gap,
                  if (isNew) ...[
                    _Checklist(
                      steps: [
                        ('Tambah akun', accountCount > 0, () => showAccountForm(context)),
                        ('Catat transaksi pertama', false, () => showRecordForm(context)),
                        ('Aktifkan catat dari notifikasi', _notifications, openNotificationAccessSettings),
                        ('Tambah tagihan rutin', _bills > 0, () => showBillForm(context)),
                      ],
                    ),
                    gap,
                    const _NoRecords(),
                  ] else ...[
                    const _QuickActions(),
                    gap,
                    if (inboxCount > 0) ...[
                      _InboxCard(count: inboxCount, rows: _inbox, onTap: () => widget.onOpenTab(1)),
                      gap,
                    ],
                    _RecentRecords(records: recent, onSeeAll: () => widget.onOpenTab(1)),
                  ],
                ],
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------- header

class _Header extends StatelessWidget {
  const _Header({required this.isNew, required this.onAvatar});

  final bool isNew;
  final VoidCallback onAvatar; // opens Pengaturan

  static String _greeting(int hour) => switch (hour) {
    >= 4 && < 10 => 'Selamat pagi',
    >= 10 && < 15 => 'Selamat siang',
    >= 15 && < 18 => 'Selamat sore',
    _ => 'Selamat malam',
  };

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final name = userDisplayName();
    final now = DateTime.now();
    return Row(
      children: [
        IconButton(
          tooltip: 'Pengaturan',
          onPressed: onAvatar,
          style: IconButton.styleFrom(backgroundColor: c.hero, fixedSize: const Size.square(46)),
          icon: Text(name[0], style: AppText.heading.copyWith(fontSize: 18, color: c.onHero)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${isNew ? 'Selamat datang' : _greeting(now.hour)}, $name',
                style: AppText.heading.copyWith(fontSize: 18),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                DateFormat('EEEE, d MMMM', 'id_ID').format(now),
                style: AppText.label.copyWith(color: c.inkMuted),
              ),
            ],
          ),
        ),
        const _SyncButton(),
      ],
    );
  }
}

/// Where this phone's data stands with the server, as an icon that follows the sync state: a cloud
/// with a check when everything is up, turning arrows while syncing, a crossed-out cloud offline.
/// Changes waiting to upload show as a count. Tap for the state in words.
class _SyncButton extends StatefulWidget {
  const _SyncButton();

  @override
  State<_SyncButton> createState() => _SyncButtonState();
}

class _SyncButtonState extends State<_SyncButton> with SingleTickerProviderStateMixin {
  late final _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  late final StreamSubscription<SyncStatus> _sub;
  SyncStatus _status = db.currentStatus;
  int _pending = 0; // changes on this phone not uploaded yet

  bool get _busy => _status.connected && (_status.uploading || _status.downloading);

  @override
  void initState() {
    super.initState();
    _sub = db.statusStream.listen((s) {
      if (!mounted) return;
      setState(() => _status = s);
      _animate();
      unawaited(_refreshPending());
    });
    _animate();
    unawaited(_refreshPending());
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    _spin.dispose();
    super.dispose();
  }

  void _animate() => _busy ? _spin.repeat() : _spin.stop();

  Future<void> _refreshPending() async {
    final n = (await db.getUploadQueueStats()).count;
    if (mounted && n != _pending) setState(() => _pending = n);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final waiting = _pending == 1 ? '1 perubahan menunggu' : '$_pending perubahan menunggu';
    final last = _status.lastSyncedAt?.toLocal();
    final (key, icon, color, label) = _busy
        ? ('busy', Icons.sync, c.primary, 'Menyinkronkan')
        : !_status.connected
        ? (
            'offline',
            Icons.cloud_off_outlined,
            c.inkMuted,
            _pending > 0 ? 'Offline, $waiting. Datanya aman di HP ini.' : 'Offline. Datanya aman di HP ini.',
          )
        : _pending > 0
        ? ('waiting', Icons.cloud_upload_outlined, c.ink, 'Tersambung, $waiting')
        : (
            'done',
            Icons.cloud_done_outlined,
            c.primary,
            last == null ? 'Semua data tersinkron' : 'Semua data tersinkron · ${DateFormat('HH.mm').format(last)}',
          );
    Widget glyph = Icon(icon, size: 22, color: color);
    if (key == 'busy') {
      glyph = RotationTransition(turns: _spin, child: glyph); // clockwise, the way the arrows point
    }
    return IconButton(
      tooltip: label,
      onPressed: () {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(label),
              action: key == 'offline' || key == 'waiting'
                  ? SnackBarAction(label: 'Coba lagi', onPressed: () => unawaited(reconnect()))
                  : null,
            ),
          );
      },
      style: IconButton.styleFrom(backgroundColor: c.surface, fixedSize: const Size.square(46)),
      icon: Badge(
        isLabelVisible: _pending > 0 && !_busy,
        backgroundColor: c.alert,
        textColor: c.onAlert,
        label: Text(_pending > 99 ? '99+' : '$_pending'),
        // A short cross-fade, so quick status flips read as one change instead of a flicker.
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: KeyedSubtree(key: ValueKey(key), child: glyph),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- balance

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({
    required this.total,
    required this.net,
    required this.caption,
    required this.hidden,
    required this.onToggleHidden,
    required this.onReport,
  });

  final int total;
  final int? net; // income minus expense this month; null hides the chip
  final String caption;
  final bool hidden;
  final VoidCallback? onToggleHidden; // null hides the eye button
  final VoidCallback? onReport;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final net = this.net;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        color: c.hero,
        borderRadius: BorderRadius.circular(AppRadius.hero),
        // On the dark background the card needs an edge (Dark · Beranda artboard).
        border: Theme.of(context).brightness == Brightness.dark ? Border.all(color: c.heroChip) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (onToggleHidden != null) ...[
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(color: c.heroChip, borderRadius: BorderRadius.circular(8)),
                  child: Icon(Icons.account_balance_wallet_outlined, size: 15, color: c.onHeroChip),
                ),
                const SizedBox(width: 8),
              ],
              Text(caption, style: AppText.label.copyWith(fontSize: 14, color: c.onHeroMuted)),
              if (onToggleHidden != null)
                IconButton(
                  tooltip: hidden ? 'Tampilkan saldo' : 'Sembunyikan saldo',
                  onPressed: onToggleHidden,
                  icon: Icon(
                    hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 18,
                    color: c.onHeroMuted,
                  ),
                ),
              const Spacer(),
              if (onReport != null)
                IconButton(
                  tooltip: 'Buka laporan',
                  onPressed: onReport,
                  icon: Icon(Icons.bar_chart, color: c.onHeroChip),
                ),
            ],
          ),
          SizedBox(height: onToggleHidden == null ? 14 : 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        'Rp',
                        style: AppText.heading.copyWith(fontSize: 18, fontWeight: FontWeight.w500, color: c.onHeroMuted),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        hidden ? '••••••' : _digits.format(total / 100).replaceFirst('-', '−'),
                        style: AppText.amountLg.copyWith(color: c.onHero, height: 1),
                      ),
                    ],
                  ),
                ),
              ),
              if (net != null) ...[
                const SizedBox(width: 8),
                Semantics(
                  label: hidden ? 'Neto bulan ini disembunyikan' : 'Neto bulan ini ${net < 0 ? 'minus ' : ''}${formatAmount(net.abs())}',
                  excludeSemantics: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.fromLTRB(4, 3, 8, 3),
                        decoration: BoxDecoration(color: c.heroChip, borderRadius: BorderRadius.circular(10)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(net < 0 ? Icons.arrow_drop_down : Icons.arrow_drop_up, size: 18, color: c.onHeroChip),
                            Text(
                              hidden ? '•••' : _compact.format(net.abs() / 100),
                              style: AppText.caption.copyWith(fontWeight: FontWeight.w600, color: c.onHeroChip),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text('neto bulan ini', style: AppText.caption.copyWith(fontSize: 11, color: c.onHeroMuted)),
                    ],
                  ),
                ),
              ],
            ],
          ),
          if (onToggleHidden == null) ...[
            const SizedBox(height: 14),
            Text(
              'Perubahan bulan ini muncul setelah kamu mulai mencatat',
              style: AppText.caption.copyWith(color: c.onHeroMuted),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- quick actions and inbox

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget action(String label, IconData icon, VoidCallback onTap) => Expanded(
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.tile),
          child: Column(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(color: c.surfaceMuted, borderRadius: BorderRadius.circular(AppRadius.tile)),
                child: Icon(icon, color: c.ink),
              ),
              const SizedBox(height: 8),
              Text(label, style: AppText.label.copyWith(fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
    void record(String type) => showRecordForm(context, prefill: Prefill(type: type));
    return Row(
      children: [
        action('Keluar', Icons.north_east, () => record('expense')),
        const SizedBox(width: AppSpace.gap),
        action('Masuk', Icons.south_west, () => record('income')),
        const SizedBox(width: AppSpace.gap),
        action('Transfer', Icons.swap_horiz, () => record('transfer')),
        const SizedBox(width: AppSpace.gap),
        action(
          'Akun',
          Icons.credit_card,
          () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const AccountsPage())),
        ),
      ],
    );
  }
}

class _InboxCard extends StatelessWidget {
  const _InboxCard({required this.count, required this.rows, required this.onTap});

  final int count;
  final List<Map<String, dynamic>> rows; // `provider`, `n` per provider
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final names = [
      for (final r in rows)
        if (r['provider'] case final String p) accountPresets.where((a) => a.provider == p).firstOrNull?.name ?? p,
    ];
    final from = names.length < 2
        ? names.join()
        : '${names.sublist(0, names.length - 1).join(', ')} dan ${names.last}';
    return Material(
      color: c.primarySoft,
      borderRadius: BorderRadius.circular(AppRadius.tile),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.tile),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle),
                child: Icon(Icons.inbox_outlined, size: 20, color: c.primary),
              ),
              const SizedBox(width: AppSpace.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$count transaksi perlu dicek', style: AppText.bodyStrong),
                    const SizedBox(height: 2),
                    Text(
                      from.isEmpty ? 'Terbaca dari notifikasi' : 'Terbaca dari notifikasi $from',
                      style: AppText.caption.copyWith(color: c.onPrimarySoft),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: c.ink),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- latest records

String _dayLabel(DateTime day, DateTime now) {
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(day.year, day.month, day.day)).inDays;
  return switch (days) {
    0 => 'Hari ini',
    1 => 'Kemarin',
    _ => DateFormat(day.year == now.year ? 'd MMM' : 'd MMM yyyy', 'id_ID').format(day),
  };
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.onSeeAll});

  final String title;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      children: [
        Expanded(child: Text(title, style: AppText.heading)),
        if (onSeeAll != null)
          TextButton(
            onPressed: onSeeAll,
            style: TextButton.styleFrom(foregroundColor: c.inkMuted, textStyle: AppText.label),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [Text('Lihat semua'), SizedBox(width: 4), Icon(Icons.arrow_forward, size: 14)],
            ),
          ),
      ],
    );
  }
}

class _RecentRecords extends StatelessWidget {
  const _RecentRecords({required this.records, required this.onSeeAll});

  final List<Map<String, dynamic>> records;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle('Transaksi terakhir', onSeeAll: onSeeAll),
        const SizedBox(height: 4),
        Material(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                for (final (i, r) in records.indexed) ...[
                  if (i > 0) const Divider(indent: 16, endIndent: 16),
                  RecordRow(r, detail: _dayLabel(DateTime.parse(r['occurred_at'] as String).toLocal(), now)),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- new user

class _Checklist extends StatelessWidget {
  const _Checklist({required this.steps});

  final List<(String, bool, VoidCallback)> steps; // label, done, what tapping it opens

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final done = steps.where((s) => s.$2).length;
    final next = steps.indexWhere((s) => !s.$2);
    return Container(
      padding: const EdgeInsets.all(AppSpace.card),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Mulai dari sini', style: AppText.heading.copyWith(fontSize: 16))),
              Text('$done dari ${steps.length}', style: AppText.label.copyWith(color: c.inkMuted)),
            ],
          ),
          const SizedBox(height: AppSpace.gap),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: done / steps.length,
              minHeight: 6,
              backgroundColor: c.surfaceMuted,
              color: c.primary,
            ),
          ),
          const SizedBox(height: AppSpace.tight),
          for (final (i, (label, isDone, onTap)) in steps.indexed)
            Semantics(
              label: isDone ? '$label, selesai' : null,
              child: InkWell(
                onTap: isDone ? null : onTap,
                borderRadius: BorderRadius.circular(AppRadius.input),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 52),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDone ? c.primary : null,
                          border: isDone ? null : Border.all(color: i == next ? c.primary : c.outline, width: 2),
                        ),
                        child: isDone ? Icon(Icons.check, size: 16, color: c.onPrimary) : null,
                      ),
                      const SizedBox(width: AppSpace.gap),
                      Expanded(
                        child: Text(
                          label,
                          style: isDone
                              ? AppText.body.copyWith(color: c.inkMuted, decoration: TextDecoration.lineThrough)
                              : AppText.body.copyWith(fontWeight: i == next ? FontWeight.w500 : null),
                        ),
                      ),
                      if (!isDone) Icon(Icons.chevron_right, size: 18, color: c.inkMuted),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NoRecords extends StatelessWidget {
  const _NoRecords();

  static const _examples = ['kopi 18rb pakai gopay', 'bensin 30rb kemarin', 'gaji masuk bca 5jt'];

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Transaksi terakhir'),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
          child: Column(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: c.primarySoft, shape: BoxShape.circle),
                child: Icon(Icons.format_list_bulleted, size: 26, color: c.primary),
              ),
              const SizedBox(height: AppSpace.gap),
              Text('Belum ada transaksi', style: AppText.heading.copyWith(fontSize: 16)),
              const SizedBox(height: 4),
              Text(
                'Ketik seperti sedang chat. Ketuk contoh di bawah untuk mencoba.',
                textAlign: TextAlign.center,
                style: AppText.label.copyWith(color: c.inkMuted),
              ),
              const SizedBox(height: AppSpace.gap),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: AppSpace.tight,
                runSpacing: AppSpace.tight,
                children: [
                  // Opens the filled-in form to look at; nothing is saved until the user taps Simpan.
                  for (final text in _examples)
                    ActionChip(label: Text(text), onPressed: () => submitQuickInput(context, text, review: true)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
