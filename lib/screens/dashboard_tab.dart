import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

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

// Beranda, after the "E · Beranda" and "Kosong · Beranda" artboards of the Cashflow UI/UX canvas.
// Until the first record exists it shows a getting-started checklist instead of the latest records.

const _syncedDot = Color(0xFF3F9A62); // the avatar's "all synced" dot in the design
final _digits = NumberFormat.decimalPattern('id_ID');
final _compact = NumberFormat.compact(locale: 'id_ID');

class DashboardTab extends StatefulWidget {
  const DashboardTab({super.key, required this.menu, required this.onOpenTab});

  /// Wraps the avatar in the app menu (categories, labels, logout).
  final Widget Function(Widget child) menu;

  /// Switches the bottom navigation: 1 Transaksi, 4 Laporan.
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
  bool _hidden = false; // ponytail: per session; persist it if people want it to stick
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
        SELECT r.*, a.name AS account_name, t.name AS target_name, c.name AS category_name
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
                padding: const EdgeInsets.fromLTRB(AppSpace.page, 16, AppSpace.page, 96), // clear of the + button
                children: [
                  _Header(
                    isNew: isNew,
                    menu: widget.menu,
                    inboxCount: inboxCount,
                    onInbox: () => widget.onOpenTab(1),
                  ),
                  gap,
                  _BalanceCard(
                    total: accounts['total'] as int,
                    net: isNew ? null : _net,
                    caption: isNew ? 'Total saldo · $accountCount akun' : 'Total saldo',
                    hidden: _hidden,
                    onToggleHidden: isNew ? null : () => setState(() => _hidden = !_hidden),
                    onReport: isNew ? null : () => widget.onOpenTab(4),
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
  const _Header({required this.isNew, required this.menu, required this.inboxCount, required this.onInbox});

  final bool isNew;
  final Widget Function(Widget child) menu;
  final int inboxCount;
  final VoidCallback onInbox;

  static String _greeting(int hour) => switch (hour) {
    >= 4 && < 10 => 'Selamat pagi',
    >= 10 && < 15 => 'Selamat siang',
    >= 15 && < 18 => 'Selamat sore',
    _ => 'Selamat malam',
  };

  /// The name from sign-up metadata, else the part of the email before "@".
  static String _name() {
    final user = supabase.auth.currentUser;
    final meta = user?.userMetadata?['name'] ?? user?.userMetadata?['full_name'];
    final name = meta is String && meta.trim().isNotEmpty ? meta.trim() : (user?.email ?? '').split('@').first;
    return name.isEmpty ? 'Kamu' : name[0].toUpperCase() + name.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final name = _name();
    final now = DateTime.now();
    return Row(
      children: [
        StreamBuilder(
          stream: db.statusStream,
          initialData: db.currentStatus, // the stream only reports changes
          builder: (context, snap) {
            final s = snap.data;
            final online = s?.connected ?? false;
            final status = !online
                ? 'offline, data aman di HP'
                : (s!.uploading || s.downloading)
                ? 'menyinkronkan'
                : 'semua data tersinkron';
            return menu(
              Semantics(
                label: 'Menu, $status',
                excludeSemantics: true,
                child: SizedBox.square(
                  dimension: 46,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: c.hero, shape: BoxShape.circle),
                          child: Center(
                            child: Text(name[0], style: AppText.heading.copyWith(fontSize: 18, color: c.onHero)),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: online ? _syncedDot : c.outline,
                            shape: BoxShape.circle,
                            border: Border.all(color: c.bg, width: 2.5, strokeAlign: BorderSide.strokeAlignOutside),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
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
        if (!isNew)
          IconButton(
            tooltip: inboxCount == 0
                ? 'Transaksi dari notifikasi'
                : '$inboxCount transaksi dari notifikasi perlu dicek',
            onPressed: onInbox,
            style: IconButton.styleFrom(backgroundColor: c.surface, fixedSize: const Size.square(46)),
            icon: Badge(
              isLabelVisible: inboxCount > 0,
              backgroundColor: c.alert,
              child: Icon(Icons.notifications_none, size: 20, color: c.ink),
            ),
          ),
      ],
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

// Icons for the default categories (supabase/migrations/0001_init.sql), matched on the name so
// renamed or new categories still get one when the word fits. First match wins.
const _categoryIcons = [
  ('makan', Icons.restaurant_outlined),
  ('belanja online', Icons.shopping_bag_outlined),
  ('belanja', Icons.shopping_cart_outlined),
  ('transport', Icons.directions_car_outlined),
  ('tagihan', Icons.bolt_outlined),
  ('tinggal', Icons.home_outlined),
  ('kesehatan', Icons.medical_services_outlined),
  ('hiburan', Icons.movie_outlined),
  ('pendidikan', Icons.school_outlined),
  ('sedekah', Icons.volunteer_activism_outlined),
  ('hadiah', Icons.card_giftcard_outlined),
  ('gaji', Icons.payments_outlined),
];

IconData _iconFor(Map<String, dynamic> r) {
  if (r['type'] == 'transfer') return Icons.swap_horiz;
  final name = ((r['category_name'] as String?) ?? '').toLowerCase();
  for (final (word, icon) in _categoryIcons) {
    if (name.contains(word)) return icon;
  }
  return r['type'] == 'income' ? Icons.account_balance_wallet_outlined : Icons.receipt_outlined;
}

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
                  _RecordRow(r, now: now),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RecordRow extends StatelessWidget {
  const _RecordRow(this.r, {required this.now});

  final Map<String, dynamic> r;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final type = r['type'] as String;
    final category = type == 'transfer'
        ? 'Transfer ke ${r['target_name'] ?? '?'}'
        : (r['category_name'] as String?) ?? 'Tanpa kategori';
    final note = (r['note'] as String?)?.trim();
    final title = note == null || note.isEmpty ? category : note;
    final subtitle = title == category ? (r['account_name'] as String? ?? '') : category;
    final amount = formatAmount(r['amount'] as int);
    final (text, color) = switch (type) {
      'income' => ('+$amount', c.income),
      'expense' => ('−$amount', c.ink),
      _ => (amount, c.ink),
    };
    final (bg, fg) = type == 'income' ? (c.primarySoft, c.primary) : (c.surfaceMuted, c.ink);
    return InkWell(
      onTap: () => showRecordForm(context, prefill: Prefill.fromRecord(r)),
      onLongPress: () => confirmDeleteRecord(context, r['id'] as String),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              child: Icon(_iconFor(r), size: 20, color: fg),
            ),
            const SizedBox(width: AppSpace.gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppText.caption.copyWith(color: c.inkMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.gap),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(text, style: AppText.amount.copyWith(color: color)),
                const SizedBox(height: 2),
                Text(
                  _dayLabel(DateTime.parse(r['occurred_at'] as String).toLocal(), now),
                  style: AppText.caption.copyWith(color: c.inkMuted),
                ),
              ],
            ),
          ],
        ),
      ),
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
