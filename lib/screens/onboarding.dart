import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../db.dart';
import '../money.dart';
import '../notifications.dart';
import '../theme.dart';
import '../ui.dart';
import 'accounts_tab.dart';
import 'login_page.dart';

// Onboarding, after the "Onboarding 1-3" artboards of the Cashflow UI/UX canvas. Step 1 greets
// everyone signed out; steps 2 and 3 follow sign-up (accounts need a signed-in user to own them).

// Illustration tints on the dark green, from the design.
const _accent = Color(0xFFA9D2B2);
const _track = Color(0xFF3C6B54);
const _deepCard = Color(0xFF163828);

/// "01 / 03" and three bars, the first [step] of them filled.
class _Progress extends StatelessWidget {
  const _Progress(this.step, {required this.on, required this.off, required this.text});

  final int step;
  final Color on;
  final Color off;
  final Color text;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Langkah $step dari 3',
    excludeSemantics: true,
    child: Row(
      children: [
        Text('0$step / 03', style: AppText.label.copyWith(color: text)),
        const SizedBox(width: 14),
        for (var i = 1; i <= 3; i++) ...[
          if (i > 1) const SizedBox(width: 6),
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(color: i <= step ? on : off, borderRadius: BorderRadius.circular(2)),
            ),
          ),
        ],
      ],
    ),
  );
}

/// Step 1, the first screen while signed out.
class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  void _login(BuildContext context, {required bool signUp}) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => LoginPage(signUp: signUp)));

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final white = c.onHero;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: c.hero,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Progress(1, on: white, off: _track, text: c.onHeroMuted),
                const SizedBox(height: 28),
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'Catat sekali,\n'),
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
                  onPressed: () => _login(context, signUp: true),
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
                TextButton(
                  onPressed: () => _login(context, signUp: false),
                  style: TextButton.styleFrom(foregroundColor: white, minimumSize: const Size.fromHeight(48)),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: 'Sudah punya akun? ', style: TextStyle(color: c.onHeroMuted)),
                        const TextSpan(
                          text: 'Masuk',
                          style: TextStyle(fontWeight: FontWeight.w600, decoration: TextDecoration.underline),
                        ),
                      ],
                    ),
                    style: AppText.label.copyWith(fontSize: 14, color: white),
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
                  Container(width: 28, height: 6, decoration: BoxDecoration(color: _accent, borderRadius: BorderRadius.circular(3))),
                  const SizedBox(width: 6),
                  Container(width: 18, height: 6, decoration: BoxDecoration(color: _track, borderRadius: BorderRadius.circular(3))),
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

/// Steps 2 and 3, right after sign-up: notification access, then the first accounts.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  int _step = 2;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _step == 2, // back on step 3 returns to step 2 instead of leaving
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _step = 2);
      },
      child: _step == 2
          ? _NotificationStep(onNext: () => setState(() => _step = 3))
          : _AccountsStep(onBack: () => setState(() => _step = 2)),
    );
  }
}

class _NotificationStep extends StatelessWidget {
  const _NotificationStep({required this.onNext});

  final VoidCallback onNext;

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
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                children: [
                  _Progress(2, on: c.primary, off: c.outline, text: c.inkMuted),
                  const SizedBox(height: 22),
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
                  FilledButton(
                    onPressed: () {
                      onNext(); // step 3 waits underneath while Android's settings are open
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
                  TextButton(
                    onPressed: onNext,
                    style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    child: const Text('Nanti saja'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountsStep extends StatefulWidget {
  const _AccountsStep({required this.onBack});

  final VoidCallback onBack;

  @override
  State<_AccountsStep> createState() => _AccountsStepState();
}

class _AccountsStepState extends State<_AccountsStep> {
  final _picked = <String>['cash']; // providers, in the order picked; a wallet almost everyone has
  final _balances = <String, TextEditingController>{};
  bool _busy = false;

  static const _groups = [
    ('Tunai dan e-wallet', {'cash', 'ewallet'}),
    ('Bank', {'bank'}),
    ('Paylater', {'paylater'}),
  ];

  @override
  void dispose() {
    for (final t in _balances.values) {
      t.dispose();
    }
    super.dispose();
  }

  void _toggle(String provider) => setState(() => _picked.contains(provider) ? _picked.remove(provider) : _picked.add(provider));

  Future<void> _finish() async {
    final presets = {for (final p in accountPresets) p.provider: p};
    // Paylater balances are what is still owed, so they are stored below zero.
    final rows = <(String, String, String, int)>[];
    for (final provider in _picked) {
      final p = presets[provider]!;
      final raw = _balances[provider]?.text.trim() ?? '';
      final amount = raw.isEmpty ? 0 : parseAmount(raw);
      if (amount == null) return showMessage(context, 'Saldo ${p.name} tidak valid. Contoh: 350.000 atau 350rb');
      rows.add((p.provider, p.name, p.type, p.type == 'paylater' ? -amount : amount));
    }
    setState(() => _busy = true);
    final now = nowIso();
    await db.writeTransaction((tx) async {
      // An account with the same provider may already have synced from another phone.
      final existing = {for (final a in await tx.getAll('SELECT provider FROM accounts')) a['provider']};
      for (final (provider, name, type, balance) in rows) {
        if (existing.contains(provider)) continue;
        await tx.execute(
          '''
          INSERT INTO accounts (id, user_id, name, type, provider, currency, initial_balance,
            archived, exclude_from_stats, created_at, updated_at)
          VALUES (uuid(), ?, ?, ?, ?, 'IDR', ?, 0, 0, ?, ?)''',
          [currentUserId, name, type, provider, balance, now, now],
        );
      }
    });
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final names = {for (final p in accountPresets) p.provider: p};
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Kembali',
                        onPressed: widget.onBack,
                        style: IconButton.styleFrom(backgroundColor: c.surface, fixedSize: const Size.square(44)),
                        icon: Icon(Icons.chevron_left, color: c.ink),
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: _Progress(3, on: c.primary, off: c.outline, text: c.inkMuted)),
                    ],
                  ),
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
                            selected: _picked.contains(p.provider),
                            onSelected: (_) => _toggle(p.provider),
                            checkmarkColor: c.onPrimary,
                            labelStyle: AppText.label.copyWith(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: _picked.contains(p.provider) ? c.onPrimary : c.ink,
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (_picked.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text('Saldo sekarang (opsional)', style: AppText.label.copyWith(color: c.inkMuted)),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
                      child: Column(
                        children: [
                          for (final (i, provider) in _picked.indexed) ...[
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
                                        Text(names[provider]!.name, style: AppText.body.copyWith(fontWeight: FontWeight.w500)),
                                        if (names[provider]!.type == 'paylater')
                                          Text('sisa tagihan', style: AppText.caption.copyWith(color: c.inkMuted)),
                                      ],
                                    ),
                                  ),
                                  Text('Rp', style: AppText.label.copyWith(fontSize: 14, color: c.inkMuted)),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 130,
                                    child: TextField(
                                      controller: _balances.putIfAbsent(provider, TextEditingController.new),
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
              padding: EdgeInsets.fromLTRB(24, 12, 24, 12 + MediaQuery.viewInsetsOf(context).bottom),
              child: FilledButton(
                onPressed: _busy ? null : (_picked.isEmpty ? () => Navigator.pop(context) : _finish),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(58),
                  textStyle: AppText.button.copyWith(fontSize: 17),
                ),
                child: Text(_picked.isEmpty ? 'Nanti saja' : 'Selesai, ${_picked.length} akun'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
