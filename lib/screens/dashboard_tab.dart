import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../money.dart';
import '../notifications.dart';
import '../reports.dart';
import '../ui.dart';
import 'accounts_tab.dart';
import 'plans_tab.dart';
import 'record_form.dart';

// Beranda: the overview tab, styled after the "Home" screen of the Financy design in Figma.
// Each section shows real data and links to the tab or page that manages it.

/// Colors from the Financy design. The design is light only, so dark mode swaps its light
/// surfaces and ink for dark ones and keeps the brand colors.
class Financy {
  const Financy._({
    required this.background,
    required this.card,
    required this.text,
    required this.muted,
    required this.dark,
  });

  final Color background; // Base/20
  final Color card; // Base/0
  final Color text; // Base/100
  final Color muted; // Base/80
  final bool dark;

  static const ink = Color(0xFF242424); // Base/100: the dark cards, and the ink of the design's icons
  static const link = Color(0xFF489FCD);
  static const income = Color(0xFF53D258); // Accent/Success/100
  static const expense = Color(0xFFE25C5C); // Accent/Error/100
  static const avatar = Color(0xFFEBB850); // Orange/80

  /// Card colors for the account carousel, in the design's order (white text on each).
  static const accountColors = [Color(0xFFE0533D), Color(0xFFE78C9D), Color(0xFF377CC8), Color(0xFF469B88)];

  /// Goal progress bars: fill and its pastel track, in the design's order.
  static const goalBars = [
    (Color(0xFFE0533D), Color(0x66CEDFBC)),
    (Color(0xFFE78C9D), Color(0x66F5E9D3)),
    (Color(0xFFEED868), Color(0x66BFA2CA)),
    (Color(0xFF377CC8), Color(0x66E6B8D0)),
  ];

  static Financy of(BuildContext context) => Theme.of(context).brightness == Brightness.dark
      ? const Financy._(
          background: Color(0xFF121212),
          card: Color(0xFF1E1E1E),
          text: Color(0xFFF3F3F3),
          muted: Color(0xFFA9A9A9),
          dark: true,
        )
      : const Financy._(
          background: Color(0xFFF3F3F3),
          card: Colors.white,
          text: ink,
          muted: Color(0xFF707070),
          dark: false,
        );
}

TextStyle _inter(double size, double height, Color color, [FontWeight weight = FontWeight.w400]) =>
    TextStyle(fontFamily: 'Inter', fontSize: size, height: height, fontWeight: weight, color: color);

TextStyle _jakarta(double size, double height, Color color) =>
    TextStyle(fontFamily: 'PlusJakartaSans', fontSize: size, height: height, fontWeight: FontWeight.w600, color: color);

const _assets = 'assets/dashboard';

/// Draws the design's #242424 ink in [ink] instead, so icons stay visible on dark surfaces.
class _InkMapper extends ColorMapper {
  const _InkMapper(this.ink);

  final Color ink;

  @override
  Color substitute(String? id, String elementName, String attributeName, Color color) =>
      color.toARGB32() == Financy.ink.toARGB32() ? ink : color;

  @override
  bool operator ==(Object other) => other is _InkMapper && other.ink == ink;

  @override
  int get hashCode => ink.hashCode;
}

Widget _svg(String name, {Color? ink}) => SvgPicture.asset(
  '$_assets/$name.svg',
  colorMapper: ink == null || ink == Financy.ink ? null : _InkMapper(ink),
  excludeFromSemantics: true,
);

class DashboardTab extends StatefulWidget {
  const DashboardTab({super.key, required this.actions, required this.onOpenTab});

  /// Sync status and the menu, the same buttons the other tabs show in their app bar.
  final List<Widget> actions;

  /// Switches the bottom navigation: 1 Transaksi, 3 Rencana.
  final ValueChanged<int> onOpenTab;

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> with WidgetsBindingObserver {
  // Streams live in the state, so a rebuild doesn't restart the queries.
  final _accounts = db.watch('''
    SELECT a.id, a.name, b.balance
    FROM accounts a JOIN ($accountBalancesSql) b ON b.id = a.id
    WHERE a.archived = 0
    ORDER BY a.name''');

  // Saved = the linked account's balance, as on the Rencana tab. Active goals first.
  final _goals = db.watch('''
    SELECT g.id, g.name, g.target_amount, g.state, COALESCE(b.balance, 0) AS saved
    FROM goals g
    LEFT JOIN ($accountBalancesSql) b ON b.id = g.account_id
    ORDER BY g.state = 'paused', g.target_date IS NULL, g.target_date, g.name
    LIMIT 4''');

  final _recent = db.watch('''
    SELECT r.*, a.name AS account_name, t.name AS target_name, c.name AS category_name, c.need_level
    FROM records r
    LEFT JOIN accounts a ON a.id = r.account_id
    LEFT JOIN accounts t ON t.id = r.transfer_account_id
    LEFT JOIN categories c ON c.id = r.category_id
    ORDER BY julianday(r.occurred_at) DESC LIMIT 5''');

  final _inboxCount = db.watch('SELECT COUNT(*) AS n FROM inbox');

  // Same rules as the Laporan tab: confirmed records on accounts that count towards statistics.
  static const _monthSql = '''
    SELECT
      COALESCE(SUM(CASE WHEN r.type = 'income' THEN r.amount END), 0) AS income,
      COALESCE(SUM(CASE WHEN r.type = 'expense' THEN r.amount END), 0) AS expense
    FROM records r JOIN accounts a ON a.id = r.account_id
    WHERE r.status = 'confirmed' AND a.exclude_from_stats = 0 AND r.type IN ('income', 'expense')
      AND julianday(r.occurred_at) >= julianday(?1) AND julianday(r.occurred_at) < julianday(?2)''';

  late DateTime _month;
  late Stream<List<Map<String, dynamic>>> _monthTotals;

  void _watchMonth() {
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    final (start, end) = periodRange('month', now);
    _monthTotals = db.watch(_monthSql, parameters: [utcIso(start), utcIso(end)]);
  }

  @override
  void initState() {
    super.initState();
    _watchMonth();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_importInbox());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Beranda is the first screen now, so it picks up new bank notifications too (the Transaksi
  // tab does the same); the bell shows when some are waiting.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_importInbox());
    final now = DateTime.now();
    if (now.year != _month.year || now.month != _month.month) setState(_watchMonth);
  }

  Future<void> _importInbox() async {
    if (await notificationAccessEnabled()) await importNotifications();
  }

  void _openAccounts() => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const AccountsPage()));

  @override
  Widget build(BuildContext context) {
    final f = Financy.of(context);
    const side = EdgeInsets.symmetric(horizontal: 24);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: f.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: ColoredBox(
        color: f.background,
        child: SafeArea(
          bottom: false,
          child: StreamBuilder(
            stream: _accounts,
            builder: (context, snap) {
              final accounts = snap.data;
              final total = accounts?.fold<int>(0, (sum, a) => sum + (a['balance'] as int)) ?? 0;
              return ListView(
                padding: const EdgeInsets.only(bottom: 96), // clear of the + button
                children: [
                  Padding(
                    padding: side,
                    child: _Header(
                      inboxCount: _inboxCount,
                      actions: widget.actions,
                      onInbox: () => widget.onOpenTab(1),
                    ),
                  ),
                  const SizedBox(height: 11),
                  Padding(
                    padding: side,
                    child: _BalanceCard(total: accounts == null ? null : total, onAccounts: _openAccounts),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: side,
                    child: StreamBuilder(
                      stream: _monthTotals,
                      builder: (context, snap) => _StatCard(totals: snap.data?.firstOrNull),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Padding(
                    padding: side,
                    child: _SectionTitle('Akun', onSeeAll: _openAccounts),
                  ),
                  const SizedBox(height: 16),
                  _AccountCarousel(accounts: accounts, onOpen: _openAccounts),
                  const SizedBox(height: 32),
                  Padding(
                    padding: side,
                    child: _SectionTitle('Goal tabungan', onSeeAll: () => widget.onOpenTab(3)),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: side,
                    child: StreamBuilder(
                      stream: _goals,
                      builder: (context, snap) => _GoalGrid(goals: snap.data, onOpen: () => widget.onOpenTab(3)),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Padding(
                    padding: side,
                    child: _SectionTitle('Transaksi', onSeeAll: () => widget.onOpenTab(1)),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: side,
                    child: StreamBuilder(
                      stream: _recent,
                      builder: (context, snap) => _RecentRecords(records: snap.data),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- header

class _Header extends StatelessWidget {
  const _Header({required this.inboxCount, required this.actions, required this.onInbox});

  final Stream<List<Map<String, dynamic>>> inboxCount;
  final List<Widget> actions;
  final VoidCallback onInbox;

  static String _greeting(int hour) => hour >= 4 && hour < 10
      ? 'Selamat pagi!'
      : hour >= 10 && hour < 15
      ? 'Selamat siang!'
      : hour >= 15 && hour < 18
      ? 'Selamat sore!'
      : 'Selamat malam!';

  /// The name from sign-up metadata, else the part of the email before "@".
  static String _name() {
    final user = supabase.auth.currentUser;
    final meta = user?.userMetadata?['name'] ?? user?.userMetadata?['full_name'];
    final name = meta is String && meta.trim().isNotEmpty ? meta.trim() : (user?.email ?? '').split('@').first;
    return name.isEmpty ? 'Kamu' : name[0].toUpperCase() + name.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final f = Financy.of(context);
    final name = _name();
    return SizedBox(
      height: 60,
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: Financy.avatar, shape: BoxShape.circle),
            child: Text(name[0], style: _inter(14, 1.2, Financy.ink, FontWeight.w600)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_greeting(DateTime.now().hour), style: _inter(12, 1.5, f.text)),
                Text(name, style: _jakarta(18, 1.35, f.text), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          StreamBuilder(
            stream: inboxCount,
            builder: (context, snap) {
              final n = (snap.data?.firstOrNull?['n'] as int?) ?? 0;
              if (n == 0) return const SizedBox.shrink();
              return IconButton(
                tooltip: '$n notifikasi transaksi perlu dicek',
                onPressed: onInbox,
                icon: _svg('bell_pin', ink: f.text),
              );
            },
          ),
          IconTheme(
            data: IconThemeData(color: f.text),
            child: Row(mainAxisSize: MainAxisSize.min, children: actions),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- balance and this month

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.total, required this.onAccounts});

  final int? total; // null while loading
  final VoidCallback onAccounts;

  @override
  Widget build(BuildContext context) {
    const white = Colors.white;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 138,
        color: Financy.ink,
        child: Stack(
          children: [
            Positioned(left: 22, top: 0, child: _svg('balance_deco_top')),
            Positioned(left: 0, bottom: 0, child: _svg('balance_deco_bottom')),
            Positioned(right: 0, top: 0, child: _svg('balance_deco_right')),
            Positioned(
              left: 18,
              top: 16,
              right: 18,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Total saldo', style: _inter(14, 1.45, white)),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(total == null ? '' : formatAmount(total!), style: _jakarta(32, 1.25, white)),
                  ),
                ],
              ),
            ),
            Positioned(
              right: 8,
              bottom: 8,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: onAccounts,
                  borderRadius: BorderRadius.circular(24),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8), // 48dp tall tap target
                    child: Row(
                      children: [
                        Text('Akun saya', style: _inter(12, 1.5, white)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(color: white, borderRadius: BorderRadius.circular(16)),
                          child: _svg('arrow_right'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.totals});

  final Map<String, dynamic>? totals; // `income`, `expense` this month; null while loading

  @override
  Widget build(BuildContext context) {
    // The decoration has a shape in two opposite corners; each half is drawn at the design's
    // size and pinned to its corner, so the shapes keep their proportions on any card width.
    Widget corner(Alignment side) => ClipRect(
      child: Align(alignment: side, widthFactor: 0.5, child: _svg('stat_deco')),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: ColoredBox(
        color: Financy.ink,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Row(
                children: [
                  Expanded(child: _StatItem('arrow_in', 'Pemasukan', totals?['income'] as int?)),
                  _svg('stat_divider'),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 26),
                      child: _StatItem('arrow_out', 'Pengeluaran', totals?['expense'] as int?),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(left: 0, top: 0, bottom: 0, child: IgnorePointer(child: corner(Alignment.topLeft))),
            Positioned(right: 0, top: 0, bottom: 0, child: IgnorePointer(child: corner(Alignment.bottomRight))),
          ],
        ),
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  const _StatItem(this.arrow, this.label, this.amount);

  final String arrow;
  final String label;
  final int? amount;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label bulan ini: ${amount == null ? '' : formatAmount(amount!)}',
      excludeSemantics: true,
      child: Row(
        children: [
          _svg(arrow),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: _inter(12, 1.5, const Color(0xFFF3F3F3))),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    amount == null ? ' ' : formatCompact(amount!),
                    style: _inter(18, 1.35, Colors.white, FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- sections

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {required this.onSeeAll});

  final String title;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final f = Financy.of(context);
    return Row(
      children: [
        Expanded(child: Text(title, style: _jakarta(20, 1.3, f.text))),
        InkWell(
          onTap: onSeeAll,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Text('Lihat semua', style: _inter(14, 1.45, Financy.link, FontWeight.w700)),
          ),
        ),
      ],
    );
  }
}

/// An empty section: one line of help and the action that fills it.
class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.text, required this.action, required this.onTap});

  final String text;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final f = Financy.of(context);
    return Material(
      color: f.card,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(child: Text(text, style: _inter(14, 1.45, f.muted))),
              const SizedBox(width: 12),
              Text(action, style: _inter(14, 1.45, Financy.link, FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountCarousel extends StatelessWidget {
  const _AccountCarousel({required this.accounts, required this.onOpen});

  final List<Map<String, dynamic>>? accounts;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final rows = accounts;
    if (rows == null) return const SizedBox(height: 130);
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: _EmptyCard(
          text: 'Belum ada akun. Mulai dari dompet, bank, atau e-wallet.',
          action: 'Tambah',
          onTap: () => showAccountForm(context),
        ),
      );
    }
    return SizedBox(
      height: 130,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        itemCount: rows.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (context, i) {
          final a = rows[i];
          final name = a['name'] as String;
          final balance = a['balance'] as int;
          return Semantics(
            button: true,
            label: '$name, saldo ${formatAmount(balance)}',
            excludeSemantics: true,
            child: Material(
              color: Financy.accountColors[i % Financy.accountColors.length],
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: onOpen,
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 125,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
                    child: Column(
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.75),
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            name.isEmpty ? '?' : name[0].toUpperCase(),
                            style: _inter(16, 1.4, Financy.ink, FontWeight.w600),
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(name, style: _inter(12, 1.5, Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(formatCompact(balance), style: _inter(18, 1.35, Colors.white, FontWeight.w600)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GoalGrid extends StatelessWidget {
  const _GoalGrid({required this.goals, required this.onOpen});

  final List<Map<String, dynamic>>? goals;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final rows = goals;
    if (rows == null) return const SizedBox(height: 91);
    if (rows.isEmpty) {
      return _EmptyCard(
        text: 'Belum ada goal. Contoh: dana darurat atau HP baru.',
        action: 'Buat',
        onTap: () => showGoalForm(context),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - 16) / 2;
        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (var i = 0; i < rows.length; i++)
              SizedBox(
                width: width,
                child: _GoalCard(goal: rows[i], bar: Financy.goalBars[i % Financy.goalBars.length], onTap: onOpen),
              ),
          ],
        );
      },
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.goal, required this.bar, required this.onTap});

  final Map<String, dynamic> goal;
  final (Color, Color) bar; // fill, track
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final f = Financy.of(context);
    final saved = goal['saved'] as int;
    final target = goal['target_amount'] as int;
    final plan = planGoal(saved: saved, target: target, now: DateTime.now());
    final paused = goal['state'] == 'paused';
    final (fill, track) = paused ? (f.muted, f.muted.withValues(alpha: 0.2)) : bar;
    final name = goal['name'] as String;
    return Semantics(
      button: true,
      label: '$name, ${formatAmount(saved)} dari ${formatAmount(target)}${paused ? ', dijeda' : ''}',
      excludeSemantics: true,
      child: Material(
        color: f.card,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 91,
            child: Stack(
              children: [
                Positioned(
                  left: 12,
                  top: 8,
                  right: 32,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: _inter(12, 1.5, f.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(formatAmount(target), style: _inter(16, 1.4, f.text, FontWeight.w600)),
                      ),
                    ],
                  ),
                ),
                Positioned(right: 12, top: 12, child: _svg('expand_right', ink: f.text)),
                Positioned(
                  left: 12,
                  right: 12,
                  top: 72,
                  child: Container(
                    height: 7,
                    decoration: BoxDecoration(color: track, borderRadius: BorderRadius.circular(7)),
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: plan.progress,
                      heightFactor: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(7)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
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
  ('belanja', Icons.shopping_basket_outlined),
  ('transport', Icons.directions_car_outlined),
  ('tagihan', Icons.receipt_long_outlined),
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

// The design's icon tints: green for money in, pink for wants (shopping), yellow for the rest.
Color _tintFor(Map<String, dynamic> r) => switch (r['type']) {
  'income' => Financy.income,
  'transfer' => const Color(0xFF9DA7D0),
  _ => r['need_level'] == 'want' ? const Color(0xFFF6BDE9) : const Color(0xFFFFCB66),
};

String _dayLabel(DateTime day, DateTime now) {
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(day.year, day.month, day.day)).inDays;
  return switch (days) {
    0 => 'Hari ini',
    1 => 'Kemarin',
    _ => DateFormat('d MMMM yyyy', 'id_ID').format(day),
  };
}

class _RecentRecords extends StatelessWidget {
  const _RecentRecords({required this.records});

  final List<Map<String, dynamic>>? records;

  @override
  Widget build(BuildContext context) {
    final rows = records;
    if (rows == null) return const SizedBox.shrink();
    if (rows.isEmpty) {
      return _EmptyCard(text: 'Belum ada transaksi.', action: 'Catat', onTap: () => showRecordForm(context));
    }
    final f = Financy.of(context);
    final now = DateTime.now();
    final children = <Widget>[];
    String? lastDay;
    for (final r in rows) {
      final day = _dayLabel(DateTime.parse(r['occurred_at'] as String).toLocal(), now);
      if (day != lastDay) {
        if (children.isNotEmpty) children.add(const SizedBox(height: 4));
        children
          ..add(Text(day, style: _inter(16, 1.4, f.muted)))
          ..add(const SizedBox(height: 12));
        lastDay = day;
      }
      children
        ..add(_RecordRow(r))
        ..add(const SizedBox(height: 12));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children..removeLast());
  }
}

class _RecordRow extends StatelessWidget {
  const _RecordRow(this.r);

  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final f = Financy.of(context);
    final type = r['type'] as String;
    final category = type == 'transfer'
        ? 'Transfer ke ${r['target_name'] ?? '?'}'
        : (r['category_name'] as String?) ?? 'Tanpa kategori';
    final note = (r['note'] as String?)?.trim();
    // Like the design's "Adobe Illustrator / Subscription fee": what it was, then its category.
    final title = note == null || note.isEmpty ? category : note;
    final subtitle = [if (title != category) category, ?r['account_name']].join(' · ');
    final amount = r['amount'] as int;
    final (sign, color) = switch (type) {
      'income' => ('+', Financy.income),
      'expense' => ('-', Financy.expense),
      _ => ('', f.text),
    };
    final tint = _tintFor(r);
    return Material(
      color: f.card,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => showRecordForm(context, prefill: Prefill.fromRecord(r)),
        onLongPress: () => confirmDeleteRecord(context, r['id'] as String),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: tint.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(20)),
                child: Icon(_iconFor(r), size: 24, color: tint),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: _inter(16, 1.4, f.text, FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(subtitle, style: _inter(14, 1.45, f.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text('$sign${formatAmount(amount)}', style: _inter(16, 1.4, color, FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}
