import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../money.dart';
import '../notifications.dart';
import '../theme.dart';
import '../ui.dart';
import 'accounts_tab.dart';
import 'login_page.dart';

// The signed-out intro, after the "Onboarding 1-3" artboards of the Cashflow UI/UX canvas: three
// pages to swipe through (welcome, notification access, first accounts), then sign-up. The picked
// accounts are created once sign-up has a user to own them.

// Illustration tints on the dark green, from the design.
const _accent = Color(0xFFA9D2B2);
const _track = Color(0xFF3C6B54);
const _deepCard = Color(0xFF163828);
const _pageDuration = Duration(milliseconds: 350);

/// 0..1 of the way from [from] to [to] seconds at [s] seconds; the demos below are timed this way.
double _seg(double s, double from, double to) => ((s - from) / (to - from)).clamp(0.0, 1.0);

/// Fades [child] in and lifts it 12 px, once, the first time [active] is true. With Android's
/// "remove animations" on, it is there from the start.
class _Entrance extends StatefulWidget {
  const _Entrance({required this.active, this.delay = Duration.zero, required this.child});

  final bool active;
  final Duration delay;
  final Widget child;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> with SingleTickerProviderStateMixin {
  static const _rise = Duration(milliseconds: 450);
  late final _clock = AnimationController(vsync: this, duration: widget.delay + _rise);
  late final _curve = CurvedAnimation(
    parent: _clock,
    curve: Interval(widget.delay.inMilliseconds / (widget.delay + _rise).inMilliseconds, 1, curve: Curves.easeOutCubic),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _start();
  }

  @override
  void didUpdateWidget(_Entrance old) {
    super.didUpdateWidget(old);
    _start();
  }

  void _start() {
    if (!widget.active || _clock.status != AnimationStatus.dismissed) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _clock.value = 1;
    } else {
      _clock.forward();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _curve,
    child: widget.child,
    builder: (context, child) => Opacity(
      opacity: _curve.value,
      child: Transform.translate(offset: Offset(0, 12 * (1 - _curve.value)), child: child),
    ),
  );
}

/// Runs a looping demo's clock only while its page is on screen, and never with animations removed.
mixin _DemoClock<T extends StatefulWidget> on State<T>, SingleTickerProviderStateMixin<T> {
  late final AnimationController clock;
  bool get active;

  /// The frame shown when animations are removed, in seconds into the loop.
  double get stillAt;

  /// Seconds into the loop for this frame.
  double get seconds =>
      MediaQuery.disableAnimationsOf(context) ? stillAt : clock.value * clock.duration!.inMilliseconds / 1000;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncClock();
  }

  void syncClock() {
    final run = active && !MediaQuery.disableAnimationsOf(context);
    if (run && !clock.isAnimating) startClock();
    if (!run && clock.isAnimating) clock.stop();
  }

  void startClock();

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }
}

/// An account picked during the intro: a preset provider and its balance in cents.
typedef StarterAccount = ({String provider, int balance});

/// Creates the intro's accounts for the user who just signed up. Providers already synced from
/// another phone are skipped, so nothing is doubled.
Future<void> createStarterAccounts(List<StarterAccount> accounts) async {
  if (accounts.isEmpty) return;
  final presets = {for (final p in accountPresets) p.provider: p};
  final now = nowIso();
  await db.writeTransaction((tx) async {
    final existing = {for (final a in await tx.getAll('SELECT provider FROM accounts')) a['provider']};
    for (final a in accounts) {
      final p = presets[a.provider];
      if (p == null || existing.contains(a.provider)) continue;
      await tx.execute(
        '''
        INSERT INTO accounts (id, user_id, name, type, provider, currency, initial_balance,
          archived, exclude_from_stats, created_at, updated_at)
        VALUES (uuid(), ?, ?, ?, ?, 'IDR', ?, 0, 0, ?, ?)''',
        [currentUserId, p.name, p.type, p.provider, a.balance, now, now],
      );
    }
  });
}

/// The page dots as drawn: "01 / 03" and three bars, the first [step] of them filled.
class _Progress extends StatelessWidget {
  const _Progress(this.step, {required this.on, required this.off, required this.text});

  final int step;
  final Color on;
  final Color off;
  final Color text;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Halaman $step dari 3',
    excludeSemantics: true,
    child: Row(
      children: [
        Text('0$step / 03', style: AppText.label.copyWith(color: text)),
        const SizedBox(width: 14),
        for (var i = 1; i <= 3; i++) ...[
          if (i > 1) const SizedBox(width: 6),
          Expanded(
            child: AnimatedContainer(
              duration: motion(context, _pageDuration),
              height: 4,
              decoration: BoxDecoration(color: i <= step ? on : off, borderRadius: BorderRadius.circular(2)),
            ),
          ),
        ],
      ],
    ),
  );
}

/// The first screen while signed out: three pages, swiped or stepped with the buttons.
class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key});

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> with WidgetsBindingObserver {
  final _pages = PageController();
  int _page = 0;
  bool _notifications = false; // access is per phone, so it may already be on from an earlier account
  final _picked = <String>['cash']; // providers, in the order picked; a wallet almost everyone has
  final _balances = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_checkNotifications());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pages.dispose();
    for (final t in _balances.values) {
      t.dispose();
    }
    super.dispose();
  }

  // Back from Android's notification-access screen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_checkNotifications());
  }

  Future<void> _checkNotifications() async {
    final enabled = await notificationAccessEnabled();
    if (!mounted || enabled == _notifications) return;
    if (enabled) haptic(Haptic.click); // back from the settings with access on: page 2 confirms it
    setState(() => _notifications = enabled);
  }

  // A zero-length page animation trips an assert, so with animations removed the page jumps.
  void _go(int page) => MediaQuery.disableAnimationsOf(context)
      ? _pages.jumpToPage(page)
      : unawaited(_pages.animateToPage(page, duration: _pageDuration, curve: Curves.easeOutCubic));

  void _login({required bool signUp, List<StarterAccount> accounts = const []}) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => LoginPage(signUp: signUp, starterAccounts: accounts),
    ),
  );

  void _signUp() {
    final presets = {for (final p in accountPresets) p.provider: p};
    final accounts = <StarterAccount>[];
    for (final provider in _picked) {
      final p = presets[provider]!;
      final raw = _balances[provider]?.text.trim() ?? '';
      final amount = raw.isEmpty ? 0 : parseAmount(raw);
      if (amount == null) return showMessage(context, 'Saldo ${p.name} tidak valid. Contoh: 350.000');
      // Paylater balances are what is still owed, so they are stored below zero.
      accounts.add((provider: provider, balance: p.type == 'paylater' ? -amount : amount));
    }
    _login(signUp: true, accounts: accounts);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final onGreen = _page == 0;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: onGreen ? SystemUiOverlayStyle.light : (Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark),
      child: PopScope(
        canPop: _page == 0, // back steps through the pages before it leaves the app
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _go(_page - 1);
        },
        child: Scaffold(
          backgroundColor: c.bg,
          body: PageView(
            controller: _pages,
            onPageChanged: (page) => setState(() => _page = page),
            children: [
              // Lewati goes straight to the accounts page: the notification pitch can wait.
              _WelcomeIntro(
                active: _page == 0,
                onNext: () => _go(1),
                onSkip: () => _go(2),
                onLogin: () => _login(signUp: false),
              ),
              _NotificationIntro(
                active: _page == 1,
                enabled: _notifications,
                onBack: () => _go(0),
                onNext: () => _go(2),
                onLogin: () => _login(signUp: false),
              ),
              _AccountsIntro(
                active: _page == 2,
                picked: _picked,
                balances: _balances,
                onToggle: (provider) => setState(
                  () => _picked.contains(provider) ? _picked.remove(provider) : _picked.add(provider),
                ),
                onBack: () => _go(1),
                onSignUp: _signUp,
                onLogin: () => _login(signUp: false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Sudah punya akun? Masuk", at the foot of every page.
class _LoginLink extends StatelessWidget {
  const _LoginLink({required this.onTap, required this.color, required this.muted});

  final VoidCallback onTap;
  final Color color;
  final Color muted;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onTap,
    style: TextButton.styleFrom(foregroundColor: color, minimumSize: const Size.fromHeight(48)),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'Sudah punya akun? ', style: TextStyle(color: muted)),
          const TextSpan(
            text: 'Masuk',
            style: TextStyle(fontWeight: FontWeight.w600, decoration: TextDecoration.underline),
          ),
        ],
      ),
      style: AppText.label.copyWith(fontSize: 14, color: color),
    ),
  );
}

/// The page header: back (from page 2), progress, and Lewati to the last page.
class _Header extends StatelessWidget {
  const _Header(this.step, {this.onBack, this.onSkip, required this.onColor});

  final int step;
  final VoidCallback? onBack;
  final VoidCallback? onSkip;
  final bool onColor; // drawn on the dark green page

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          if (onBack != null) ...[
            IconButton(
              tooltip: 'Kembali',
              onPressed: onBack,
              style: IconButton.styleFrom(backgroundColor: c.surface, fixedSize: const Size.square(44)),
              icon: Icon(Icons.chevron_left, color: c.ink),
            ),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: _Progress(
              step,
              on: onColor ? c.onHero : c.primary,
              off: onColor ? _track : c.outline,
              text: onColor ? c.onHeroMuted : c.inkMuted,
            ),
          ),
          if (onSkip != null) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: onSkip,
              style: TextButton.styleFrom(foregroundColor: onColor ? c.onHero : c.primary),
              child: const Text('Lewati'),
            ),
          ],
        ],
      ),
    );
  }
}

class _WelcomeIntro extends StatelessWidget {
  const _WelcomeIntro({required this.active, required this.onNext, required this.onSkip, required this.onLogin});

  final bool active;
  final VoidCallback onNext;
  final VoidCallback onSkip;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final white = c.onHero;
    return ColoredBox(
      color: c.hero,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(1, onSkip: onSkip, onColor: true),
              const SizedBox(height: 20),
              _Entrance(
                active: active,
                child: Text.rich(
                  const TextSpan(
                    children: [
                      TextSpan(text: 'Catat sekali,\n'),
                      TextSpan(
                        text: 'tahu ke mana uangmu pergi.',
                        style: TextStyle(color: _accent),
                      ),
                    ],
                  ),
                  style: AppText.title.copyWith(fontSize: 40, height: 1.08, letterSpacing: -0.8, color: white),
                ),
              ),
              const SizedBox(height: 14),
              _Entrance(
                active: active,
                delay: const Duration(milliseconds: 120),
                child: Text(
                  'Cukup ketik satu kalimat, atau biarkan notifikasi bank yang mencatat. Tetap jalan tanpa internet.',
                  style: AppText.body.copyWith(fontSize: 16, height: 1.5, color: c.onHeroMuted),
                ),
              ),
              Expanded(
                child: ExcludeSemantics(child: _Illustration(active: active)),
              ),
              FilledButton(
                onPressed: onNext,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(58),
                  backgroundColor: c.surface,
                  foregroundColor: c.ink,
                  textStyle: AppText.button.copyWith(fontSize: 17),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Text('Mulai'), SizedBox(width: 10), Icon(Icons.arrow_forward, size: 20)],
                ),
              ),
              const SizedBox(height: 4),
              _LoginLink(onTap: onLogin, color: white, muted: c.onHeroMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the first page's demo types, and the record each line becomes. Demo values only; the
/// categories match the defaults every new user gets (supabase/migrations/0001_init.sql).
const _demos = [
  (line: 'kopi 18rb pakai gopay', category: 'Makan & Minum', delta: -1800000, account: 'GoPay'),
  (line: 'bensin 30rb', category: 'Transportasi', delta: -3000000, account: 'Dompet'),
  (line: 'gaji masuk bca 5jt', category: 'Gaji', delta: 500000000, account: 'BCA'),
];

final _digits = NumberFormat.decimalPattern('id_ID');

/// Three stacked cards, as drawn, playing the product: a line is typed, becomes a record, and the
/// balance moves. One line every five seconds, while the page is on screen.
class _Illustration extends StatefulWidget {
  const _Illustration({required this.active});

  final bool active;

  @override
  State<_Illustration> createState() => _IllustrationState();
}

class _IllustrationState extends State<_Illustration> with SingleTickerProviderStateMixin, _DemoClock {
  int _demo = 0;
  int _balance = 845000000; // Rp 8.450.000 in cents, before the current line lands

  @override
  bool get active => widget.active;

  @override
  double get stillAt => 3; // the record landed, the balance moved

  @override
  void initState() {
    super.initState();
    clock = AnimationController(vsync: this, duration: const Duration(seconds: 5))
      ..addStatusListener((status) {
        if (status != AnimationStatus.completed) return;
        setState(() {
          _balance += _demos[_demo].delta;
          _demo = (_demo + 1) % _demos.length;
        });
        clock.forward(from: 0);
      });
  }

  @override
  void didUpdateWidget(_Illustration old) {
    super.didUpdateWidget(old);
    syncClock();
  }

  @override
  void startClock() => clock.forward();

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(animation: clock, builder: (context, _) => _frame(context, seconds)),
  );

  Widget _frame(BuildContext context, double s) {
    final c = AppColors.of(context);
    final demo = _demos[_demo];
    final typed = (_seg(s, 0.3, 0.3 + demo.line.length * 0.045) * demo.line.length).round();
    final landed = s >= 1.5;
    final fadeOut = 1 - _seg(s, 4.4, 4.8);
    final rise = Curves.easeOutCubic.transform(_seg(s, 1.5, 1.9));
    // The caret blinks while waiting for the next line and stays solid while typing.
    final caret = !landed && (typed > 0 || (s * 2.5).floor().isEven);
    Widget card(Color color, double angle, Offset shift, {Widget? child, bool shadow = false}) => Center(
      child: Transform.translate(
        offset: shift,
        child: Transform.rotate(
          angle: angle,
          child: Container(
            width: 250,
            height: 150,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(24),
              boxShadow: shadow
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 40,
                        offset: const Offset(0, 18),
                      ),
                    ]
                  : null,
            ),
            child: child,
          ),
        ),
      ),
    );
    final bubble = BoxDecoration(
      color: c.surface,
      borderRadius: BorderRadius.circular(20),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 20, offset: const Offset(0, 8))],
    );
    return Stack(
      children: [
        card(const Color(0xFFDDE9DE), 0.157, const Offset(18, -20)),
        card(const Color(0xFF7FAF8C), -0.105, const Offset(-10, -6)),
        card(
          _deepCard,
          0,
          Offset.zero,
          shadow: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total saldo', style: AppText.label.copyWith(color: c.onHeroMuted)),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('Rp', style: AppText.body.copyWith(color: c.onHeroMuted)),
                    const SizedBox(width: 6),
                    CountUp(
                      landed ? _balance + demo.delta : _balance,
                      builder: (v) => Text(
                        _digits.format(v ~/ 100),
                        style: AppText.amountLg.copyWith(fontSize: 30, height: 1, color: c.onHero),
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 28,
                    height: 6,
                    decoration: BoxDecoration(color: _accent, borderRadius: BorderRadius.circular(3)),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    width: 18,
                    height: 6,
                    decoration: BoxDecoration(color: _track, borderRadius: BorderRadius.circular(3)),
                  ),
                ],
              ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          top: 20,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: bubble,
            child: Opacity(
              opacity: fadeOut,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(demo.line.substring(0, typed), style: AppText.label.copyWith(fontSize: 14, color: c.ink)),
                  // Kept in the layout when hidden, so the bubble does not twitch as it blinks.
                  Opacity(
                    opacity: caret ? 1 : 0,
                    child: Container(width: 2, height: 18, margin: const EdgeInsets.only(left: 1), color: c.primary),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 16,
          child: Opacity(
            opacity: rise * fadeOut,
            child: Transform.translate(
              offset: Offset(0, 12 * (1 - rise)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: bubble.copyWith(borderRadius: BorderRadius.circular(18)),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(color: c.hero, shape: BoxShape.circle),
                      child: Icon(Icons.check, size: 16, color: c.onHero),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          demo.category,
                          style: AppText.label.copyWith(fontWeight: FontWeight.w600, color: c.ink),
                        ),
                        Text(
                          '${demo.delta < 0 ? '−' : '+'}${formatAmount(demo.delta.abs())} · ${demo.account}',
                          style: AppText.caption.copyWith(color: c.inkMuted),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The second page's demo, on a loop, drawn like the "Perlu dicek" card in Transaksi: a bank
/// notification arrives, becomes an item waiting to be checked, and is swiped right to save.
class _NotificationDemo extends StatefulWidget {
  const _NotificationDemo({required this.active});

  final bool active;

  @override
  State<_NotificationDemo> createState() => _NotificationDemoState();
}

class _NotificationDemoState extends State<_NotificationDemo> with SingleTickerProviderStateMixin, _DemoClock {
  @override
  bool get active => widget.active;

  @override
  double get stillAt => 1.5; // the item is waiting to be checked

  @override
  void initState() {
    super.initState();
    clock = AnimationController(vsync: this, duration: const Duration(milliseconds: 5800));
  }

  @override
  void didUpdateWidget(_NotificationDemo old) {
    super.didUpdateWidget(old);
    syncClock();
  }

  @override
  void startClock() => clock.repeat();

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(animation: clock, builder: (context, _) => _frame(context, seconds)),
  );

  Widget _frame(BuildContext context, double s) {
    final c = AppColors.of(context);
    final out = 1 - _seg(s, 5.2, 5.6); // the saved state clears before the next notification
    final arrive = Curves.easeOutCubic.transform(_seg(s, 0, 0.4));
    final arrow = _seg(s, 0.45, 0.7) * out;
    final item = Curves.easeOutCubic.transform(_seg(s, 0.7, 1.1));
    final swipe = Curves.easeInOutCubic.transform(_seg(s, 2.2, 2.9)) * 0.42;
    final gone = Curves.easeInCubic.transform(_seg(s, 3.2, 3.5));
    final saved = Curves.easeOutCubic.transform(_seg(s, 3.6, 4)) * out;
    final radius = BorderRadius.circular(18);
    return Container(
      padding: const EdgeInsets.all(AppSpace.card),
      decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(AppRadius.card)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The notification stays: each loop it arrives again, as the next one would.
          Opacity(
            opacity: 0.4 + 0.6 * arrive,
            child: Transform.translate(
              offset: Offset(0, -8 * (1 - arrive)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(color: c.surface, borderRadius: radius),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: c.surfaceMuted, borderRadius: BorderRadius.circular(10)),
                      child: Text('BCA', style: AppText.caption.copyWith(fontSize: 10, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('BCA mobile · sekarang', style: AppText.label.copyWith(fontWeight: FontWeight.w600)),
                          Text(
                            'Transaksi debit Rp 150.000 QRIS ALFAMART KUNINGAN berhasil',
                            style: AppText.caption.copyWith(color: c.inkMuted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Opacity(
            opacity: arrow,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Icon(Icons.arrow_downward, size: 20, color: c.primary),
            ),
          ),
          Opacity(
            opacity: item * out,
            child: Padding(
              padding: const EdgeInsets.only(left: 4, bottom: AppSpace.tight),
              child: Row(
                children: [
                  Expanded(child: Text('Perlu dicek', style: AppText.bodyStrong.copyWith(fontSize: 14))),
                  Icon(Icons.swap_horiz, size: 14, color: c.onPrimarySoft),
                  const SizedBox(width: 4),
                  Text('geser untuk memilih', style: AppText.caption.copyWith(color: c.onPrimarySoft)),
                ],
              ),
            ),
          ),
          // Clipped like a list row, so the swiped item leaves through the edge instead of over it.
          ClipRRect(
            borderRadius: radius,
            child: Stack(
              children: [
                // Behind the item, as in Transaksi: a swipe right shows Simpan.
                Positioned.fill(
                  child: Opacity(
                    opacity: swipe > 0 ? 1 - _seg(s, 3.4, 3.7) : 0,
                    child: Container(
                      decoration: BoxDecoration(color: c.primary, borderRadius: radius),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          Icon(Icons.check, color: c.onPrimary),
                          const SizedBox(width: 8),
                          Text('Simpan', style: AppText.bodyStrong.copyWith(fontSize: 14, color: c.onPrimary)),
                        ],
                      ),
                    ),
                  ),
                ),
                Opacity(
                  opacity: item * (1 - gone),
                  child: FractionalTranslation(
                    translation: Offset(swipe + gone * 0.7, 0.15 * (1 - item)),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                      decoration: BoxDecoration(color: c.surface, borderRadius: radius),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: c.surfaceMuted, shape: BoxShape.circle),
                            child: Text(
                              'BCA',
                              style: AppText.caption.copyWith(fontSize: 11, fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(width: AppSpace.gap),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('−${formatAmount(15000000)}', style: AppText.amount),
                                const SizedBox(height: 2),
                                Text(
                                  'Belanja Harian · QRIS ALFAMART KUNINGAN',
                                  style: AppText.caption.copyWith(color: c.inkMuted),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Where the item was, once saved.
                Positioned.fill(
                  child: Opacity(
                    opacity: saved,
                    child: Transform.translate(
                      offset: Offset(0, 6 * (1 - saved)),
                      child: Row(
                        children: [
                          const SizedBox(width: 14),
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(color: c.primary, shape: BoxShape.circle),
                            child: Icon(Icons.check, size: 20, color: c.onPrimary),
                          ),
                          const SizedBox(width: AppSpace.gap),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Tersimpan', style: AppText.bodyStrong.copyWith(fontSize: 14)),
                                Text(
                                  'Belanja Harian · −${formatAmount(15000000)} · BCA',
                                  style: AppText.caption.copyWith(color: c.onPrimarySoft),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
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

class _NotificationIntro extends StatelessWidget {
  const _NotificationIntro({
    required this.active,
    required this.enabled,
    required this.onBack,
    required this.onNext,
    required this.onLogin,
  });

  final bool active;
  final bool enabled;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget point(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.gap),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle),
            child: Icon(icon, size: 18, color: c.primary),
          ),
          const SizedBox(width: AppSpace.gap),
          Expanded(
            child: Text(text, style: AppText.label.copyWith(fontSize: 14, height: 1.4, color: c.ink)),
          ),
        ],
      ),
    );
    final button = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(58),
      textStyle: AppText.button.copyWith(fontSize: 17),
    );
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              children: [
                _Header(2, onBack: onBack, onSkip: onNext, onColor: false),
                const SizedBox(height: 20),
                _Entrance(
                  active: active,
                  child: Text(
                    'Catat otomatis dari notifikasi bank',
                    style: AppText.title.copyWith(fontSize: 30, height: 1.12, letterSpacing: -0.5),
                  ),
                ),
                const SizedBox(height: 10),
                _Entrance(
                  active: active,
                  delay: const Duration(milliseconds: 120),
                  child: Text(
                    'Setiap ada transaksi di BCA, GoPay, DANA, dan lainnya, Cashflow menyiapkan catatannya. '
                    'Kamu tinggal cek, lalu simpan.',
                    style: AppText.body.copyWith(height: 1.5, color: c.inkMuted),
                  ),
                ),
                const SizedBox(height: 22),
                ExcludeSemantics(child: _NotificationDemo(active: active)),
                const SizedBox(height: 22),
                point(Icons.account_balance_outlined, 'Yang dibaca hanya notifikasi bank dan e-wallet'),
                // The text goes to Gemini (parse-transaction) after redact() in notifications.dart.
                point(Icons.lock_outline, 'Nama, email, dan nomor rekening dihapus di HP sebelum AI membacanya'),
                point(Icons.fact_check_outlined, 'Tidak ada yang tersimpan sebelum kamu cek'),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            // The page stays while Android's settings are open and turns to "aktif" on the way back,
            // so the user sees that it worked before moving on.
            child: AnimatedSwitcher(
              duration: motion(context, const Duration(milliseconds: 250)),
              child: Column(
                key: ValueKey(enabled),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (enabled) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle, size: 18, color: c.primary),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text('Akses notifikasi sudah aktif', style: AppText.label.copyWith(fontSize: 14)),
                        ),
                        TextButton(
                          onPressed: openNotificationAccessSettings,
                          style: TextButton.styleFrom(
                            textStyle: AppText.label.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          child: const Text('Atur'),
                        ),
                      ],
                    ),
                    FilledButton(onPressed: onNext, style: button, child: const Text('Lanjut')),
                  ] else ...[
                    Text(
                      'Di pengaturan Android, nyalakan Cashflow lalu kembali ke sini.',
                      textAlign: TextAlign.center,
                      style: AppText.label.copyWith(fontSize: 14, color: c.inkMuted),
                    ),
                    const SizedBox(height: AppSpace.tight),
                    FilledButton(
                      onPressed: openNotificationAccessSettings,
                      style: button,
                      child: const Text('Izinkan akses notifikasi'),
                    ),
                  ],
                  _LoginLink(onTap: onLogin, color: c.primary, muted: c.inkMuted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountsIntro extends StatelessWidget {
  const _AccountsIntro({
    required this.active,
    required this.picked,
    required this.balances,
    required this.onToggle,
    required this.onBack,
    required this.onSignUp,
    required this.onLogin,
  });

  final bool active;
  final List<String> picked;
  final Map<String, TextEditingController> balances;
  final ValueChanged<String> onToggle;
  final VoidCallback onBack;
  final VoidCallback onSignUp;
  final VoidCallback onLogin;

  static const _groups = [
    ('Tunai dan e-wallet', {'cash', 'ewallet'}),
    ('Bank', {'bank'}),
    ('Paylater', {'paylater'}),
  ];

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final presets = {for (final p in accountPresets) p.provider: p};
    // Chips arrive one after another, in reading order, the first time the page shows.
    final order = {for (final (i, p) in accountPresets.indexed) p.provider: i};
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
              children: [
                _Header(3, onBack: onBack, onColor: false),
                const SizedBox(height: 20),
                _Entrance(
                  active: active,
                  child: Text(
                    'Uangmu disimpan di mana saja?',
                    style: AppText.title.copyWith(fontSize: 30, height: 1.12, letterSpacing: -0.5),
                  ),
                ),
                const SizedBox(height: 8),
                _Entrance(
                  active: active,
                  delay: const Duration(milliseconds: 120),
                  child: Text(
                    'Pilih semua yang kamu pakai. Bisa ditambah atau diubah nanti.',
                    style: AppText.body.copyWith(height: 1.5, color: c.inkMuted),
                  ),
                ),
                for (final (title, types) in _groups) ...[
                  const SizedBox(height: 20),
                  Text(title, style: AppText.label.copyWith(color: c.inkMuted)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in accountPresets.where((p) => types.contains(p.type)))
                        _Entrance(
                          active: active,
                          delay: Duration(milliseconds: 200 + 35 * order[p.provider]!),
                          child: FilterChip(
                            label: Text(p.name),
                            selected: picked.contains(p.provider),
                            onSelected: (_) {
                              haptic(Haptic.tick);
                              onToggle(p.provider);
                            },
                            checkmarkColor: c.onPrimary,
                            labelStyle: AppText.label.copyWith(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: picked.contains(p.provider) ? c.onPrimary : c.ink,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                // The balance rows grow and shrink with the picks instead of jumping. AnimatedSize
                // asserts on a zero duration, so with animations removed the rows simply appear.
                if (MediaQuery.disableAnimationsOf(context))
                  if (picked.isNotEmpty) _balanceRows(c, presets) else const SizedBox.shrink()
                else
                  AnimatedSize(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: picked.isEmpty ? const SizedBox(width: double.infinity) : _balanceRows(c, presets),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  onPressed: onSignUp,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(58),
                    textStyle: AppText.button.copyWith(fontSize: 17),
                  ),
                  child: AnimatedSwitcher(
                    duration: motion(context, const Duration(milliseconds: 200)),
                    child: Text(
                      picked.isEmpty ? 'Daftar' : 'Daftar, ${picked.length} akun',
                      key: ValueKey(picked.length),
                    ),
                  ),
                ),
                _LoginLink(onTap: onLogin, color: c.primary, muted: c.inkMuted),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _balanceRows(AppColors c, Map<String, ({String provider, String name, String type})> presets) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 20),
      Text('Saldo sekarang (opsional)', style: AppText.label.copyWith(color: c.inkMuted)),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
        child: Column(
          children: [
            for (final (i, provider) in picked.indexed) ...[
              if (i > 0) const Divider(),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 60),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(presets[provider]!.name, style: AppText.body.copyWith(fontWeight: FontWeight.w500)),
                          if (presets[provider]!.type == 'paylater')
                            Text('sisa tagihan', style: AppText.caption.copyWith(color: c.inkMuted)),
                        ],
                      ),
                    ),
                    Text('Rp', style: AppText.label.copyWith(fontSize: 14, color: c.inkMuted)),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 130,
                      child: TextField(
                        controller: balances.putIfAbsent(provider, TextEditingController.new),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: const [AmountInputFormatter()],
                        textAlign: TextAlign.right,
                        style: AppText.body.copyWith(fontWeight: FontWeight.w500),
                        decoration: InputDecoration(
                          hintText: '0',
                          fillColor: c.bg,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    ],
  );
}
