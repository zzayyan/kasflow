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
  String? _busy; // 'form' or 'google': the button that started the request shows the spinner
  bool _showPassword = false;
  String? _confirmEmail; // set once sign-up has sent a confirmation link; the page waits for the sign-in

  /// A user made in the last day is the one who just signed up here, even after an email
  /// confirmation. An older one came from elsewhere, and their accounts sync down instead.
  static bool _isNew(User user) =>
      DateTime.now().difference(DateTime.parse(user.createdAt)) < const Duration(hours: 24);

  Future<void> _finish(User? user) async {
    if (user != null && _isNew(user)) await createStarterAccounts(widget.starterAccounts);
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst); // the root swaps to Beranda
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy != null) return; // the keyboard's done key still submits while a request runs
    final email = _email.text.trim();
    final password = _password.text;
    // Without this, an empty email reaches Supabase as an anonymous sign-up ("Anonymous sign-ins are disabled").
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return showMessage(context, 'Isi email yang valid, contoh nama@gmail.com');
    }
    // New passwords need 8; signing in accepts whatever an older account was made with.
    if (_signUp && password.length < 8) return showMessage(context, 'Password minimal 8 karakter.');
    if (!_signUp && password.isEmpty) return showMessage(context, 'Isi password.');
    setState(() => _busy = 'form');
    try {
      if (_signUp) {
        final name = _name.text.trim();
        final res = await supabase.auth.signUp(
          email: email,
          password: password,
          data: name.isEmpty ? null : {'name': name},
        );
        if (res.session == null) {
          // Email confirmation is on: the account exists once the link is opened. The page stays
          // on Masuk with the email and password kept, so coming back is one tap.
          if (mounted) {
            setState(() {
              _signUp = false;
              _confirmEmail = email;
            });
          }
          return;
        }
        await _finish(res.user);
      } else {
        // The starter accounts picked in the intro are made here too, after an email confirmation.
        await _finish((await supabase.auth.signInWithPassword(email: email, password: password)).user);
      }
    } on AuthException catch (e) {
      _authError(e, email);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Supabase's messages are English and name no way out; these say what to do next.
  void _authError(AuthException e, [String? email]) {
    if (!mounted) return;
    switch (e.code) {
      case 'invalid_credentials':
        return showMessage(context, 'Email atau password salah. Periksa lagi, lalu coba masuk.');
      case 'user_already_exists' || 'email_exists':
        setState(() => _signUp = false); // keeps what was typed, so signing in is one tap
        return showMessage(context, 'Email ini sudah terdaftar. Masuk dengan password-nya.');
      case 'email_not_confirmed':
        setState(() => _confirmEmail = email);
        return showMessage(context, 'Email belum dikonfirmasi. Buka link di email, lalu masuk lagi.');
      case 'weak_password':
        return showMessage(context, 'Password terlalu mudah ditebak. Coba yang lebih panjang.');
      case 'over_request_rate_limit' || 'over_email_send_rate_limit':
        return showMessage(context, 'Terlalu banyak percobaan. Tunggu beberapa menit, lalu coba lagi.');
    }
    if (e is AuthRetryableFetchException) {
      return showMessage(context, 'Tidak bisa terhubung. Periksa internet, lalu coba lagi.');
    }
    showMessage(context, e.message);
  }

  Future<void> _google() async {
    haptic(Haptic.click);
    setState(() => _busy = 'google');
    try {
      final user = await signInWithGoogle();
      if (user == null) return; // picker canceled
      await _finish(user); // Google may resolve to an existing user, whom _isNew tells apart
    } on AuthException catch (e) {
      _authError(e);
    } on GoogleSignInException {
      if (mounted) showMessage(context, 'Tidak bisa masuk dengan Google. Coba lagi.');
    } finally {
      if (mounted) setState(() => _busy = null);
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
                        _signUp
                            ? 'Buat akun'
                            : _confirmEmail != null
                            ? 'Satu langkah lagi'
                            : 'Selamat datang lagi',
                        style: AppText.title.copyWith(fontSize: 30, letterSpacing: -0.5, color: c.onHero),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _signUp
                            ? 'Satu akun untuk semua HP-mu.'
                            : _confirmEmail != null
                            // Stays until the sign-in, unlike a snackbar: the user leaves for the email app.
                            ? 'Link konfirmasi terkirim ke $_confirmEmail. Buka link itu, lalu masuk di sini.'
                            : 'Masuk untuk lanjut mencatat.',
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
                              'Nama panggilan (opsional)',
                              _name,
                              TextField(
                                controller: _name,
                                textCapitalization: TextCapitalization.words,
                                textInputAction: TextInputAction.next,
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
                              textInputAction: TextInputAction.next,
                              autocorrect: false,
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
                              autocorrect: false, // also once the password is shown
                              enableSuggestions: false,
                              textInputAction: TextInputAction.done,
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
                      onPressed: _busy != null ? null : _submit,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(58),
                        textStyle: AppText.button.copyWith(fontSize: 17),
                      ),
                      child: _busy == 'form'
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
                          // divider is drawn for rows on a card; on the page background it vanished
                          Expanded(child: Divider(color: c.surfaceMuted)),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text('atau', style: AppText.caption.copyWith(color: c.inkMuted)),
                          ),
                          Expanded(child: Divider(color: c.surfaceMuted)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: _busy != null ? null : _google,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(58),
                          textStyle: AppText.button.copyWith(fontSize: 17),
                        ),
                        child: _busy == 'google'
                            ? SizedBox.square(
                                dimension: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.4, color: c.ink),
                              )
                            : const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [_GoogleMark(), SizedBox(width: 12), Text('Lanjut dengan Google')],
                              ),
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

/// Google's "G", drawn from the official 48x48 sign-in button SVG, so no SVG package is needed.
/// Brand colors on purpose: Google's guidelines keep the mark in its own colors in light and dark.
class _GoogleMark extends StatelessWidget {
  const _GoogleMark();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.square(dimension: 20, child: CustomPaint(painter: _GooglePainter()));
}

class _GooglePainter extends CustomPainter {
  const _GooglePainter();

  static final _parts = [
    (
      0xFFEA4335,
      Path()
        ..moveTo(24, 9.5)
        ..cubicTo(27.54, 9.5, 30.71, 10.72, 33.21, 13.1)
        ..lineTo(40.06, 6.25)
        ..cubicTo(35.9, 2.38, 30.47, 0, 24, 0)
        ..cubicTo(14.62, 0, 6.51, 5.38, 2.56, 13.22)
        ..lineTo(10.54, 19.41)
        ..cubicTo(12.43, 13.72, 17.74, 9.5, 24, 9.5)
        ..close(),
    ),
    (
      0xFF4285F4,
      Path()
        ..moveTo(46.98, 24.55)
        ..cubicTo(46.98, 22.98, 46.83, 21.46, 46.6, 20)
        ..lineTo(24, 20)
        ..lineTo(24, 29.02)
        ..lineTo(36.94, 29.02)
        ..cubicTo(36.36, 31.98, 34.68, 34.5, 32.16, 36.2)
        ..lineTo(39.89, 42.2)
        ..cubicTo(44.4, 38.02, 46.98, 31.84, 46.98, 24.55)
        ..close(),
    ),
    (
      0xFFFBBC05,
      Path()
        ..moveTo(10.53, 28.59)
        ..cubicTo(10.05, 27.14, 9.77, 25.6, 9.77, 24)
        ..cubicTo(9.77, 22.4, 10.04, 20.86, 10.53, 19.41)
        ..lineTo(2.55, 13.22)
        ..cubicTo(0.92, 16.46, 0, 20.12, 0, 24)
        ..cubicTo(0, 27.88, 0.92, 31.54, 2.56, 34.78)
        ..lineTo(10.53, 28.59)
        ..close(),
    ),
    (
      0xFF34A853,
      Path()
        ..moveTo(24, 48)
        ..cubicTo(30.48, 48, 35.93, 45.87, 39.89, 42.19)
        ..lineTo(32.16, 36.19)
        ..cubicTo(30.01, 37.64, 27.24, 38.49, 24, 38.49)
        ..cubicTo(17.74, 38.49, 12.43, 34.27, 10.53, 28.58)
        ..lineTo(2.55, 34.77)
        ..cubicTo(6.51, 42.62, 14.62, 48, 24, 48)
        ..close(),
    ),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 48);
    for (final (color, path) in _parts) {
      canvas.drawPath(path, Paint()..color = Color(color));
    }
  }

  @override
  bool shouldRepaint(_GooglePainter oldDelegate) => false;
}
