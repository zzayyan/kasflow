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
import 'plans_tab.dart';
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
  StreamSubscription<void>? _weekSub;
  List<Map<String, dynamic>> _weekRows = const []; // expenses of the last 14 days
  late DateTime _today;
  int _weekDay = 6; // the selected column of the week chart; 6 = today
  List<Map<String, dynamic>>? _recent;
  Map<String, dynamic>? _accounts; // `n`, `total`
  List<Map<String, dynamic>> _inbox = const []; // `provider`, `n`
  int _bills = 0;
  List<BudgetView> _budgets = const [];
  String? _pickedBudgetId; // chosen by tapping "Jatah hari ini" (pref 'home_budget')
  BudgetView? get _budget => mainBudget(_budgets, pickedId: _pickedBudgetId);
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

  // Fourteen days: this week's seven and the seven before, to compare with.
  void _watchWeek() {
    final now = DateTime.now();
    _today = DateTime(now.year, now.month, now.day);
    _weekDay = 6;
    unawaited(_weekSub?.cancel());
    _weekSub = _watch(
      '''
      SELECT r.type, r.amount, r.occurred_at
      FROM records r JOIN accounts a ON a.id = r.account_id
      WHERE r.type = 'expense' AND r.status = 'confirmed' AND a.exclude_from_stats = 0
        AND julianday(r.occurred_at) >= julianday(?1)''',
      (rows) => _weekRows = rows,
      [utcIso(DateTime(_today.year, _today.month, _today.day - 13))],
    );
  }

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
      _watch('SELECT provider, COUNT(*) AS n FROM inbox WHERE amount IS NOT NULL GROUP BY provider', (rows) => _inbox = rows),
      _watch('SELECT COUNT(*) AS n FROM planned_payments', (rows) => _bills = rows.first['n'] as int),
      watchBudgets().listen((rows) => _set(() => _budgets = rows)),
      // Watched, not read once: Rencana can also make a budget the one Beranda follows.
      _watch(
        "SELECT value FROM prefs WHERE id = 'home_budget'",
        (rows) => _pickedBudgetId = rows.firstOrNull?['value'] as String?,
      ),
    ]);
    _watchMonth();
    _watchWeek();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_importInbox());
    unawaited(getPref('hide_balance').then((v) => v == '1' ? _set(() => _hidden = true) : null));
  }

  /// Which budget "Jatah hari ini" follows. With none yet, Rencana is where one is made.
  Future<void> _pickBudget() async {
    if (_budgets.isEmpty) return widget.onOpenTab(2);
    final current = _budget?.row['id'];
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Jatah harian dari budget', style: AppText.heading),
            ),
            for (final b in _budgets)
              ListTile(
                title: Text(b.row['name'] as String),
                subtitle: Text(
                  '${periodLabels[b.row['period']] ?? 'Custom'} · ${formatAmount(b.row['amount'] as int)}',
                ),
                selected: b.row['id'] == current,
                trailing: b.row['id'] == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, b.row['id'] as String),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    _set(() => _pickedBudgetId = picked);
    await setPref('home_budget', picked);
  }

  void _set(VoidCallback change) {
    if (mounted) setState(change);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in [..._subs, ?_monthSub, ?_weekSub]) {
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
    if (DateTime(now.year, now.month, now.day) != _today) setState(_watchWeek); // past midnight
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
                    allowance: isNew
                        ? null
                        : _AllowancePanel(budget: _budget, hidden: _hidden, onTap: _pickBudget),
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
                    _WeekSpending(
                      totals: dayTotals(_weekRows, _today, 14, 'expense'),
                      today: _today,
                      selected: _weekDay,
                      onSelect: (i) => setState(() => _weekDay = i),
                    ),
                    gap,
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
    this.allowance,
  });

  final Widget? allowance; // "Jatah hari ini" at the bottom of the card
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
          if (allowance case final a?) ...[const SizedBox(height: 14), a],
        ],
      ),
    );
  }
}

/// "Jatah hari ini": what the main budget still allows per day for the rest of its period, so a
/// thrifty day raises tomorrow's figure and a costly one lowers it. Without a budget it invites
/// setting one; once the budget is spent it turns to the alert color. Tapping it picks the budget.
class _AllowancePanel extends StatelessWidget {
  const _AllowancePanel({required this.budget, required this.hidden, required this.onTap});

  final BudgetView? budget;
  final bool hidden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final b = budget;
    final now = DateTime.now();
    final limit = b?.row['amount'] as int? ?? 0;
    final (_, end) = periodRange(b?.row['period'] as String? ?? 'month', now);
    // Fixed at the start of the day, then each purchase today takes its full amount off.
    final today = b == null ? null : todayAllowance(b.spent, b.spentToday, limit, end, now);
    final exhausted = b != null && today == null; // nothing was left before today
    final overToday = today != null && today.left < 0;
    final over = exhausted || overToday;
    final daysLeft = DateTime(end.year, end.month, end.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    String money(int cents) => hidden ? 'Rp •••' : formatAmount(cents);
    String short(int cents) => hidden ? 'Rp •••' : formatCompact(cents);

    final (IconData icon, String title, String detail) = switch (b) {
      null => (Icons.savings_outlined, 'Atur budget untuk melihat jatah harian', 'Buka Rencana'),
      _ when exhausted => (
        Icons.warning_amber_rounded,
        'Budget ${b.row['name']} habis',
        b.spent > limit ? 'Terlewat ${money(b.spent - limit)}' : 'Tidak ada sisa sampai periode berikutnya',
      ),
      _ when overToday => (
        Icons.warning_amber_rounded,
        'Jatah hari ini terlewat',
        '${b.row['name']} · jatah ${short(today.perDay)}, terpakai ${short(b.spentToday)}',
      ),
      _ => (
        Icons.verified_user_outlined,
        'Jatah hari ini',
        b.spentToday == 0
            ? '${b.row['name']} · sisa ${short(limit - b.spent)}, $daysLeft hari lagi'
            : '${b.row['name']} · terpakai ${short(b.spentToday)} dari ${short(today!.perDay)}',
      ),
    };
    final fg = over ? c.alert : c.onHero;
    return Material(
      color: over ? c.alertSoft : c.heroChip,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: over ? c.surface : c.hero, shape: BoxShape.circle),
                child: Icon(icon, size: 18, color: over ? c.alert : c.onHeroChip),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Short title on one line; the detail (budget name first) may take two.
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(color: over ? c.alert : c.onHeroChip, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(fontSize: 11, color: over ? c.alert : c.onHeroMuted),
                    ),
                  ],
                ),
              ),
              if (today != null) ...[
                const SizedBox(width: 8),
                Text(
                  overToday ? '−${money(-today.left)}' : money(today.left),
                  style: AppText.amount.copyWith(fontSize: 20, color: fg),
                ),
              ] else if (b == null)
                Icon(Icons.chevron_right, size: 20, color: c.onHeroChip),
            ],
          ),
        ),
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

// ---------------------------------------------------------------- the last seven days

/// Spending per day for the last week: the total, how it compares with the week before (an arrow
/// and words, not color alone), and one column per day. Tapping a column shows that day.
/// "Rp 59 rb", for the chart's chip and average line.
String _short(int cents) => cents == 0 ? 'Rp 0' : 'Rp ${NumberFormat.compact(locale: 'id_ID').format(cents / 100)}';

class _WeekSpending extends StatelessWidget {
  const _WeekSpending({required this.totals, required this.today, required this.selected, required this.onSelect});

  final List<int> totals; // 14 days, oldest first, ending today
  final DateTime today;
  final int selected; // 0-6 within the last seven
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final week = totals.sublist(7);
    final before = totals.take(7).fold<int>(0, (sum, v) => sum + v);
    final total = week.fold<int>(0, (sum, v) => sum + v);
    final days = [for (var i = 0; i < 7; i++) DateTime(today.year, today.month, today.day - 6 + i)];
    final change = percentChange(total, before);
    final (IconData icon, String text, Color color) = switch (change) {
      // Nothing to compare with yet (a new user's first weeks): say so rather than leave a gap.
      null => (Icons.remove, 'Belum ada pengeluaran di 7 hari sebelumnya', c.inkMuted),
      final p when p.round() == 0 => (Icons.remove, 'Sama dengan 7 hari sebelumnya', c.inkMuted),
      final p when p < 0 => (Icons.arrow_downward, '${p.abs().round()}% lebih hemat dari 7 hari sebelumnya', c.income),
      final p => (Icons.arrow_upward, '${p.round()}% lebih banyak dari 7 hari sebelumnya', c.alert),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.hero)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Pengeluaran 7 hari terakhir', style: AppText.heading.copyWith(fontSize: 16)),
          const SizedBox(height: 6),
          Text(formatAmount(total), style: AppText.amount.copyWith(fontSize: 22)),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  text,
                  style: AppText.caption.copyWith(color: color, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          if (total == 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text('Belum ada pengeluaran 7 hari terakhir.', style: AppText.label.copyWith(color: c.inkMuted)),
            )
          else
            SelectableBars(
              values: week,
              labels: [for (final d in days) d == today ? 'Hari ini' : DateFormat('E', 'id_ID').format(d)],
              readouts: [
                for (final (i, d) in days.indexed)
                  '${DateFormat('EEEE, d MMMM', 'id_ID').format(d)}: ${formatAmount(week[i])}',
              ],
              selected: selected,
              onSelect: onSelect,
              valueText: _short,
              average: total ~/ 7,
              averageText: 'rata-rata ${_short(total ~/ 7)}',
              height: 110,
            ),
        ],
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
