import 'dart:async';

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:logging/logging.dart';

import 'db.dart';
import 'theme.dart';
import 'ui.dart';

// "Kunci dengan sidik jari": with it on, Flowku opens behind a lock that the phone's fingerprint
// (or its PIN, pattern or password) lifts.

/// Pengaturan's switch (pref 'app_lock'); off unless turned on.
final appLockOn = ValueNotifier(false);

/// How long the app may sit in the background before it locks again, so copying a code from
/// another app does not cost a fingerprint each time.
const lockAfter = Duration(minutes: 1);

final _auth = LocalAuthentication();
final _log = Logger('app_lock');

/// The phone's fingerprint or screen lock, asked with [reason]. True when the user passed it, false
/// when they cancelled or failed, null when the phone has no screen lock to ask with.
Future<bool?> confirmOwner(String reason) async {
  try {
    if (!await _auth.isDeviceSupported()) return null;
    return await _auth.authenticate(localizedReason: reason, persistAcrossBackgrounding: true);
  } on LocalAuthException catch (e) {
    _log.warning('authentication failed: ${e.code}', e);
    return false;
  }
}

/// Covers [child], the whole app, while it is locked.
class AppLock extends StatefulWidget {
  const AppLock({super.key, required this.child});

  final Widget child;

  @override
  State<AppLock> createState() => _AppLockState();
}

class _AppLockState extends State<AppLock> with WidgetsBindingObserver {
  late bool _locked = _shouldLock;
  DateTime? _leftAt;
  bool _asking = false;

  // Signed out there is nothing to hide, and the login screen must stay reachable.
  bool get _shouldLock => appLockOn.value && supabase.auth.currentSession != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The fingerprint prompt itself only makes the app inactive, so it never counts as leaving.
    if (state == AppLifecycleState.paused) _leftAt ??= DateTime.now();
    if (state != AppLifecycleState.resumed) return;
    final away = _leftAt == null ? Duration.zero : DateTime.now().difference(_leftAt!);
    _leftAt = null;
    if (!_locked && _shouldLock && away >= lockAfter) {
      setState(() => _locked = true);
      unawaited(_unlock());
    }
  }

  Future<void> _unlock() async {
    if (_asking) return;
    _asking = true;
    // A phone whose screen lock was removed meanwhile cannot ask, so it opens.
    final ok = await confirmOwner('Buka Flowku') ?? true;
    _asking = false;
    if (ok && mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      if (_locked) Positioned.fill(child: _LockScreen(onUnlock: _unlock)),
    ],
  );
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Material(
      color: c.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.page),
          child: Column(
            children: [
              const Spacer(),
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(color: c.hero, shape: BoxShape.circle),
                child: Icon(Icons.lock_outline, size: 32, color: c.onHero),
              ),
              const SizedBox(height: 18),
              Text('Flowku terkunci', style: AppText.title.copyWith(fontSize: 20)),
              const SizedBox(height: 6),
              Text(
                'Buka dengan sidik jari atau kunci layar HP.',
                textAlign: TextAlign.center,
                style: AppText.label.copyWith(color: c.inkMuted),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () {
                  haptic(Haptic.tick);
                  onUnlock();
                },
                icon: const Icon(Icons.fingerprint),
                label: const Text('Buka'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
