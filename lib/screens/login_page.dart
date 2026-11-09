import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../db.dart';
import '../theme.dart';
import '../ui.dart';
import 'onboarding.dart';

// Masuk / Daftar, after the "Login" artboard of the Cashflow UI/UX canvas.

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.signUp = false, this.starterAccounts = const []});

  final bool signUp; // open on Daftar instead of Masuk
  final List<StarterAccount> starterAccounts; // picked in the intro, created on sign-up

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late bool _signUp = widget.signUp;
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    // Without this, an empty email reaches Supabase as an anonymous sign-up ("Anonymous sign-ins are disabled").
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return showMessage(context, 'Isi email yang valid, contoh nama@gmail.com');
    }
    // New passwords need 8; signing in accepts whatever an older account was made with.
    if (_signUp && password.length < 8) return showMessage(context, 'Password minimal 8 karakter.');
    if (!_signUp && password.isEmpty) return showMessage(context, 'Isi password.');
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      if (_signUp) {
        final name = _name.text.trim();
        final res = await supabase.auth.signUp(
          email: email,
          password: password,
          data: name.isEmpty ? null : {'name': name},
        );
        if (res.session == null) {
          // Email confirmation is on: the account exists once the link is opened.
          if (mounted) {
            setState(() => _signUp = false);
            showMessage(context, 'Cek email untuk konfirmasi, lalu masuk di sini.');
          }
          return;
        }
        await createStarterAccounts(widget.starterAccounts);
        nav.popUntil((route) => route.isFirst); // the app's root swaps to Beranda on the new session
      } else {
        await supabase.auth.signInWithPassword(email: email, password: password);
        nav.popUntil((route) => route.isFirst);
      }
    } on AuthException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _google() async {
    haptic(Haptic.click);
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      final user = await signInWithGoogle();
      if (user == null) return; // picker canceled
      // Google can resolve to an existing user (same verified email). Their accounts sync down from
      // the server, so the intro's starter accounts only go to a user created just now.
      if (DateTime.now().difference(DateTime.parse(user.createdAt)) < const Duration(minutes: 1)) {
        await createStarterAccounts(widget.starterAccounts);
      }
      nav.popUntil((route) => route.isFirst);
    } on AuthException catch (e) {
      if (mounted) showMessage(context, e.message);
    } on GoogleSignInException {
      if (mounted) showMessage(context, 'Tidak bisa masuk dengan Google. Coba lagi.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget field(String label, TextEditingController controller, Widget input) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(label, style: AppText.label.copyWith(color: c.inkMuted)),
          ),
          input,
        ],
      ),
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light, // light icons on the dark green top
      child: Scaffold(
        body: Column(
          children: [
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: c.hero,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(36)),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (Navigator.canPop(context))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: IconButton(
                            tooltip: 'Kembali',
                            onPressed: () => Navigator.pop(context),
                            style: IconButton.styleFrom(backgroundColor: c.heroChip, fixedSize: const Size.square(44)),
                            icon: Icon(Icons.chevron_left, color: c.onHero),
                          ),
                        ),
                      Container(
                        width: 52,
                        height: 52,
                        // White tile, green mark: the same in light and dark, like the hero behind it.
                        decoration: BoxDecoration(color: c.onHero, borderRadius: BorderRadius.circular(16)),
                        child: Icon(Icons.show_chart, size: 28, color: c.hero),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        _signUp ? 'Buat akun' : 'Selamat datang lagi',
                        style: AppText.title.copyWith(fontSize: 30, letterSpacing: -0.5, color: c.onHero),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _signUp ? 'Satu akun untuk semua HP-mu.' : 'Masuk untuk lanjut mencatat.',
                        style: AppText.body.copyWith(color: c.onHeroMuted, height: 1.45),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: SafeArea(
                top: false,
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    PillSwitch(
                      options: const [(false, 'Masuk'), (true, 'Daftar')],
                      value: _signUp,
                      onChanged: (v) => setState(() => _signUp = v),
                    ),
                    const SizedBox(height: 16),
                    AutofillGroup(
                      child: Column(
                        children: [
                          if (_signUp)
                            field(
                              'Nama panggilan',
                              _name,
                              TextField(
                                controller: _name,
                                textCapitalization: TextCapitalization.words,
                                autofillHints: const [AutofillHints.nickname],
                                decoration: const InputDecoration(hintText: 'contoh: Zayyan'),
                              ),
                            ),
                          field(
                            'Email',
                            _email,
                            TextField(
                              controller: _email,
                              keyboardType: TextInputType.emailAddress,
                              autofillHints: const [AutofillHints.email],
                              decoration: const InputDecoration(hintText: 'nama@email.com'),
                            ),
                          ),
                          field(
                            'Password',
                            _password,
                            TextField(
                              controller: _password,
                              obscureText: !_showPassword,
                              autofillHints: [_signUp ? AutofillHints.newPassword : AutofillHints.password],
                              onSubmitted: (_) => _submit(),
                              decoration: InputDecoration(
                                hintText: _signUp ? 'minimal 8 karakter' : null,
                                suffixIcon: IconButton(
                                  tooltip: _showPassword ? 'Sembunyikan password' : 'Tampilkan password',
                                  onPressed: () => setState(() => _showPassword = !_showPassword),
                                  icon: Icon(
                                    _showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                    color: c.inkMuted,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(58),
                        textStyle: AppText.button.copyWith(fontSize: 17),
                      ),
                      child: _busy
                          ? SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.4, color: c.onPrimary),
                            )
                          : Text(_signUp ? 'Daftar' : 'Masuk'),
                    ),
                    if (googleWebClientId.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(child: Divider(color: c.divider)),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text('atau', style: AppText.caption.copyWith(color: c.inkMuted)),
                          ),
                          Expanded(child: Divider(color: c.divider)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: _busy ? null : _google,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(58),
                          textStyle: AppText.button.copyWith(fontSize: 17),
                        ),
                        child: const Text('Lanjut dengan Google'),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      'Data disimpan di HP dan disinkronkan ke akunmu, jadi tetap aman kalau ganti HP.',
                      textAlign: TextAlign.center,
                      style: AppText.caption.copyWith(color: c.inkMuted, height: 1.4),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
