import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'db.dart';
import 'screens/home_page.dart';
import 'screens/onboarding.dart';
import 'theme.dart';
import 'ui.dart';

final _log = Logger('app');

/// Sends every log record and every uncaught error to logcat, release builds included, so a bug on
/// the phone can be read with `adb logcat -s flutter`. ponytail: logcat only keeps recent lines;
/// keep a file or a Supabase table when bugs need reading long after they happen.
void _reportErrors() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) {
    debugPrint('[${r.loggerName}] ${r.level.name}: ${r.message}${r.error == null ? '' : ' | ${r.error}'}');
    if (r.stackTrace != null) debugPrint('${r.stackTrace}');
  });
  FlutterError.onError = (details) {
    FlutterError.presentError(details); // the red screen and console dump in debug
    _log.severe('widget error', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _log.severe('uncaught error', error, stack);
    return true; // logged; keep the app running
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _reportErrors();
  if (supabaseUrl.isEmpty || supabasePublishableKey.isEmpty || powersyncUrl.isEmpty) {
    runApp(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('Config missing: run with --dart-define-from-file=.env'))),
      ),
    );
    return;
  }
  await initializeDateFormatting('id_ID');
  await openDatabase();
  themeMode.value = themeModeFromPref(await getPref('theme'));
  hapticsOn.value = await getPref('haptics') != '0';
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: themeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'Cashflow',
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        themeMode: mode,
        home: StreamBuilder<AuthState>(
          stream: supabase.auth.onAuthStateChange,
          builder: (context, _) => supabase.auth.currentSession == null ? const WelcomePage() : const HomePage(),
        ),
      ),
    );
  }
}
