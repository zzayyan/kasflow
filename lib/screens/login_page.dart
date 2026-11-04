import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../db.dart';
import '../ui.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  Future<void> _submit({required bool signUp}) async {
    final email = _email.text.trim();
    // Without this, an empty email reaches Supabase as an anonymous sign-up ("Anonymous sign-ins are disabled").
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return showMessage(context, 'Isi email yang valid, contoh nama@gmail.com');
    }
    if (_password.text.length < 6) return showMessage(context, 'Password minimal 6 karakter.');
    setState(() => _busy = true);
    try {
      if (signUp) {
        final res = await supabase.auth.signUp(email: email, password: _password.text);
        if (res.session == null && mounted) showMessage(context, 'Cek email Anda untuk konfirmasi, lalu masuk.');
      } else {
        await supabase.auth.signInWithPassword(email: email, password: _password.text);
      }
    } on AuthException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 48),
            Text('Cashflow', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 24),
            TextField(
              controller: _email,
              decoration: const InputDecoration(labelText: 'Email'),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
            ),
            TextField(
              controller: _password,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
              autofillHints: const [AutofillHints.password],
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _busy ? null : () => _submit(signUp: false), child: const Text('Masuk')),
            TextButton(onPressed: _busy ? null : () => _submit(signUp: true), child: const Text('Daftar akun baru')),
          ],
        ),
      ),
    );
  }
}
