import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    if (mounted && enabled != _notifications) setState(() => _notifications = enabled);
  }

  void _go(int page) => _pages.animateToPage(
    page,
    duration: motion(context, _pageDuration),
    curve: Curves.easeOutCubic,
  );

  void _login({required bool signUp, List<StarterAccount> accounts = const []}) => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => LoginPage(signUp: signUp, starterAccounts: accounts)),
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
              _WelcomeIntro(onNext: () => _go(1), onSkip: () => _go(2), onLogin: () => _login(signUp: false)),
              _NotificationIntro(
                enabled: _notifications,
                onBack: () => _go(0),
                onNext: () => _go(2),
                onLogin: () => _login(signUp: false),
              ),
              _AccountsIntro(
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
  const _WelcomeIntro({required this.onNext, required this.onSkip, required this.onLogin});

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
              Text.rich(
                const TextSpan(
                  children: [
                    TextSpan(text: 'Catat sekali,\n'),
                    TextSpan(text: 'tahu ke mana uangmu pergi.', style: TextStyle(color: _accent)),
                  ],
                ),
                style: AppText.title.copyWith(fontSize: 40, height: 1.08, letterSpacing: -0.8, color: white),
              ),
              const SizedBox(height: 14),
              Text(
                'Cukup ketik satu kalimat, atau biarkan notifikasi bank yang mencatat. Tetap jalan tanpa internet.',
                style: AppText.body.copyWith(fontSize: 16, height: 1.5, color: c.onHeroMuted),
              ),
              const Expanded(child: ExcludeSemantics(child: _Illustration())),
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

/// Three stacked cards with a quick-input line and the record it became, as drawn.
class _Illustration extends StatelessWidget {
  const _Illustration();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
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
                  ? [BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 40, offset: const Offset(0, 18))]
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
                    Text('8.450.000', style: AppText.amountLg.copyWith(fontSize: 30, height: 1, color: c.onHero)),
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
            child: Text('bakso 25rb pakai dana', style: AppText.label.copyWith(fontSize: 14, color: c.ink)),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 16,
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
                    Text('Makan & Minum', style: AppText.label.copyWith(fontWeight: FontWeight.w600, color: c.ink)),
                    Text('−Rp 25.000 · DANA', style: AppText.caption.copyWith(color: c.inkMuted)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NotificationIntro extends StatelessWidget {
  const _NotificationIntro({required this.enabled, required this.onBack, required this.onNext, required this.onLogin});

  final bool enabled;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget point(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle),
            child: Icon(icon, size: 18, color: c.primary),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: AppText.label.copyWith(fontSize: 14, height: 1.4, color: c.ink))),
        ],
      ),
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
                Text(
                  'Catat otomatis dari notifikasi bank',
                  style: AppText.title.copyWith(fontSize: 30, height: 1.12, letterSpacing: -0.5),
                ),
                const SizedBox(height: 10),
                Text(
                  'Setiap ada transaksi di BCA, GoPay, DANA, dan lainnya, Cashflow menyiapkan catatannya. '
                  'Kamu tinggal cek lalu simpan.',
                  style: AppText.body.copyWith(height: 1.5, color: c.inkMuted),
                ),
                const SizedBox(height: 22),
                // Before and after, as drawn: a bank notification becomes a record waiting to be checked.
                ExcludeSemantics(
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(26)),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(18)),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: c.surfaceMuted,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  'BCA',
                                  style: AppText.caption.copyWith(fontSize: 10, fontWeight: FontWeight.w700),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'BCA mobile · sekarang',
                                      style: AppText.label.copyWith(fontWeight: FontWeight.w600),
                                    ),
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
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Icon(Icons.arrow_downward, size: 22, color: c.primary),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(18)),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(color: c.surfaceMuted, shape: BoxShape.circle),
                                child: Icon(Icons.shopping_basket_outlined, size: 20, color: c.ink),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Belanja Harian', style: AppText.bodyStrong.copyWith(fontSize: 14)),
                                    Text('BCA · perlu dicek', style: AppText.caption.copyWith(color: c.inkMuted)),
                                  ],
                                ),
                              ),
                              Text('−${formatAmount(15000000)}', style: AppText.amount.copyWith(fontSize: 14)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                point(Icons.account_balance_outlined, 'Hanya notifikasi aplikasi bank dan e-wallet yang dibaca'),
                point(Icons.lock_outline, 'Isi notifikasi tetap di HP ini, tidak dikirim ke server'),
                point(Icons.check, 'Tidak ada yang tersimpan sebelum kamu cek'),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (enabled)
                  FilledButton.icon(
                    onPressed: onNext,
                    icon: const Icon(Icons.check, size: 20),
                    label: const Text('Akses notifikasi aktif · Lanjut'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(58),
                      textStyle: AppText.button.copyWith(fontSize: 17),
                    ),
                  )
                else ...[
                  FilledButton(
                    onPressed: () {
                      onNext(); // the next page waits underneath while Android's settings are open
                      openNotificationAccessSettings();
                    },
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(58),
                      textStyle: AppText.button.copyWith(fontSize: 17),
                    ),
                    child: const Text('Izinkan akses notifikasi'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Kamu akan dibawa ke pengaturan Android',
                    textAlign: TextAlign.center,
                    style: AppText.caption.copyWith(color: c.inkMuted),
                  ),
                ],
                _LoginLink(onTap: onLogin, color: c.primary, muted: c.inkMuted),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountsIntro extends StatelessWidget {
  const _AccountsIntro({
    required this.picked,
    required this.balances,
    required this.onToggle,
    required this.onBack,
    required this.onSignUp,
    required this.onLogin,
  });

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
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
              children: [
                _Header(3, onBack: onBack, onColor: false),
                const SizedBox(height: 20),
                Text(
                  'Uangmu disimpan di mana saja?',
                  style: AppText.title.copyWith(fontSize: 30, height: 1.12, letterSpacing: -0.5),
                ),
                const SizedBox(height: 8),
                Text(
                  'Pilih semua yang kamu pakai. Bisa ditambah atau diubah nanti.',
                  style: AppText.body.copyWith(height: 1.5, color: c.inkMuted),
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
                        FilterChip(
                          label: Text(p.name),
                          selected: picked.contains(p.provider),
                          onSelected: (_) => onToggle(p.provider),
                          checkmarkColor: c.onPrimary,
                          labelStyle: AppText.label.copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: picked.contains(p.provider) ? c.onPrimary : c.ink,
                          ),
                        ),
                    ],
                  ),
                ],
                if (picked.isNotEmpty) ...[
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
                                      Text(
                                        presets[provider]!.name,
                                        style: AppText.body.copyWith(fontWeight: FontWeight.w500),
                                      ),
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
                  child: Text(picked.isEmpty ? 'Daftar' : 'Daftar, ${picked.length} akun'),
                ),
                _LoginLink(onTap: onLogin, color: c.primary, muted: c.inkMuted),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
