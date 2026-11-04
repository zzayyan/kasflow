import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'db.dart';
import 'screens/home_page.dart';
import 'screens/onboarding.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cashflow',
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: StreamBuilder<AuthState>(
        stream: supabase.auth.onAuthStateChange,
        builder: (context, _) => supabase.auth.currentSession == null ? const WelcomePage() : const HomePage(),
      ),
    );
  }
}
