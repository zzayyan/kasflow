import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'db.dart';
import 'money.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (supabaseUrl.isEmpty || supabasePublishableKey.isEmpty || powersyncUrl.isEmpty) {
    runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('Config missing: run with --dart-define-from-file=.env'))),
    ));
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
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: StreamBuilder<AuthState>(
        stream: supabase.auth.onAuthStateChange,
        builder: (context, _) => supabase.auth.currentSession == null ? const LoginPage() : const HomePage(),
      ),
    );
  }
}

void showMessage(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

// ---------------------------------------------------------------- login

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

// ---------------------------------------------------------------- home

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  Future<void> _logout() async {
    if (!await logout() && mounted) {
      showMessage(context, 'Masih ada data yang belum tersinkron. Sambungkan internet dulu, lalu coba lagi.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_tab == 0 ? 'Transaksi' : 'Akun'),
        actions: [
          StreamBuilder(
            stream: db.statusStream,
            builder: (context, snap) {
              final s = snap.data;
              final (icon, label) = s == null || !s.connected
                  ? (Icons.cloud_off, 'Offline: data aman di HP, sync saat online')
                  : (s.uploading || s.downloading)
                      ? (Icons.cloud_sync, 'Menyinkronkan')
                      : (Icons.cloud_done, 'Tersinkron');
              return IconButton(icon: Icon(icon), tooltip: label, onPressed: () => showMessage(context, label));
            },
          ),
          IconButton(icon: const Icon(Icons.logout), tooltip: 'Keluar', onPressed: _logout),
        ],
      ),
      body: _tab == 0 ? const RecordsTab() : const AccountsTab(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _tab == 0 ? showRecordForm(context) : showAccountForm(context),
        child: const Icon(Icons.add),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Transaksi'),
          NavigationDestination(icon: Icon(Icons.account_balance_wallet), label: 'Akun'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- records (A1)

class RecordsTab extends StatelessWidget {
  const RecordsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      // ponytail: newest 500 only; add paging when a user has more history than that.
      stream: db.watch('''
        SELECT r.*, a.name AS account_name, t.name AS target_name, c.name AS category_name
        FROM records r
        LEFT JOIN accounts a ON a.id = r.account_id
        LEFT JOIN accounts t ON t.id = r.transfer_account_id
        LEFT JOIN categories c ON c.id = r.category_id
        ORDER BY r.occurred_at DESC LIMIT 500'''),
      builder: (context, snap) {
        final rows = snap.data;
        if (rows == null) return const Center(child: CircularProgressIndicator());
        if (rows.isEmpty) return const Center(child: Text('Belum ada transaksi. Tekan + untuk mencatat.'));
        final date = DateFormat('d MMM yyyy', 'id_ID');
        return ListView.separated(
          itemCount: rows.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = rows[i];
            final type = r['type'] as String;
            final title = type == 'transfer'
                ? 'Transfer ke ${r['target_name'] ?? '?'}'
                : (r['category_name'] as String?) ?? 'Tanpa kategori';
            final subtitle = [
              r['account_name'],
              date.format(DateTime.parse(r['occurred_at'] as String).toLocal()),
              if ((r['note'] as String?)?.isNotEmpty ?? false) r['note'],
            ].join(' · ');
            final amount = r['amount'] as int;
            return ListTile(
              title: Text(title),
              subtitle: Text(subtitle),
              trailing: Text(
                '${type == 'income' ? '+' : type == 'expense' ? '-' : ''}${formatAmount(amount)}',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: type == 'income' ? Colors.green.shade700 : type == 'expense' ? Colors.red.shade700 : null,
                ),
              ),
              onLongPress: () => _confirmDelete(context, r['id'] as String),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus transaksi?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (ok == true) await db.execute('DELETE FROM records WHERE id = ?', [id]);
  }
}

Future<void> showRecordForm(BuildContext context) async {
  final accounts = await db.getAll('SELECT id, name, currency FROM accounts WHERE archived = 0 ORDER BY name');
  if (!context.mounted) return;
  if (accounts.isEmpty) {
    showMessage(context, 'Buat akun dulu di tab Akun.');
    return;
  }
  final categories = await db.getAll('SELECT id, name, type FROM categories WHERE archived = 0 ORDER BY name');
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => RecordForm(accounts: accounts, categories: categories),
  );
}

class RecordForm extends StatefulWidget {
  const RecordForm({super.key, required this.accounts, required this.categories});

  final List<Map<String, dynamic>> accounts;
  final List<Map<String, dynamic>> categories;

  @override
  State<RecordForm> createState() => _RecordFormState();
}

class _RecordFormState extends State<RecordForm> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String _type = 'expense';
  late String _accountId = widget.accounts.first['id'] as String;
  String? _targetId;
  String? _categoryId;
  DateTime _date = DateTime.now();

  Future<void> _save() async {
    final amount = parseAmount(_amount.text);
    if (amount == null) return showMessage(context, 'Nominal tidak valid. Contoh: 25.000 atau 25rb');
    if (_type == 'transfer' && (_targetId == null || _targetId == _accountId)) {
      return showMessage(context, 'Pilih akun tujuan yang berbeda.');
    }
    final currency = widget.accounts.firstWhere((a) => a['id'] == _accountId)['currency'];
    final now = nowIso();
    await db.execute('''
      INSERT INTO records (id, user_id, account_id, type, amount, currency, category_id,
        transfer_account_id, transfer_amount, note, occurred_at, status, source, created_at, updated_at)
      VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'confirmed', 'manual', ?, ?)''', [
      currentUserId, _accountId, _type, amount, currency,
      _type == 'transfer' ? null : _categoryId,
      _type == 'transfer' ? _targetId : null,
      _type == 'transfer' ? amount : null, // ponytail: same-currency transfers only; ask for received amount when currencies differ
      _note.text.trim().isEmpty ? null : _note.text.trim(),
      _date.toUtc().toIso8601String(), now, now,
    ]);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final categories = widget.categories.where((c) => c['type'] == _type).toList();
    DropdownMenuItem<String> accountItem(Map<String, dynamic> a) =>
        DropdownMenuItem(value: a['id'] as String, child: Text(a['name'] as String));
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton(
            segments: const [
              ButtonSegment(value: 'expense', label: Text('Keluar')),
              ButtonSegment(value: 'income', label: Text('Masuk')),
              ButtonSegment(value: 'transfer', label: Text('Transfer')),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() {
              _type = s.first;
              _categoryId = null;
            }),
          ),
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Nominal', prefixText: 'Rp '),
          ),
          DropdownButtonFormField(
            initialValue: _accountId,
            decoration: InputDecoration(labelText: _type == 'transfer' ? 'Dari akun' : 'Akun'),
            items: widget.accounts.map(accountItem).toList(),
            onChanged: (v) => setState(() => _accountId = v!),
          ),
          if (_type == 'transfer')
            DropdownButtonFormField(
              initialValue: _targetId,
              decoration: const InputDecoration(labelText: 'Ke akun'),
              items: widget.accounts.where((a) => a['id'] != _accountId).map(accountItem).toList(),
              onChanged: (v) => setState(() => _targetId = v),
            )
          else
            DropdownButtonFormField(
              key: ValueKey(_type), // reset when switching income/expense
              initialValue: _categoryId,
              decoration: const InputDecoration(labelText: 'Kategori'),
              items: [
                for (final c in categories)
                  DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String)),
              ],
              onChanged: (v) => setState(() => _categoryId = v),
            ),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'Catatan (opsional)')),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: Text(DateFormat('EEEE, d MMMM yyyy', 'id_ID').format(_date)),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(2000),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (picked != null) {
                final now = DateTime.now();
                setState(() => _date = DateTime(picked.year, picked.month, picked.day, now.hour, now.minute));
              }
            },
          ),
          FilledButton(onPressed: _save, child: const Text('Simpan')),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- accounts (A2 + B4 presets)

const accountTypes = {
  'cash': 'Tunai',
  'bank': 'Rekening bank',
  'ewallet': 'E-wallet',
  'paylater': 'Paylater',
  'credit_card': 'Kartu kredit',
  'savings': 'Tabungan',
  'investment': 'Investasi',
  'loan': 'Pinjaman',
};

// B4: one tap fills name, type and provider. Order = rough popularity in Indonesia.
const accountPresets = [
  (provider: 'cash', name: 'Dompet', type: 'cash'),
  (provider: 'gopay', name: 'GoPay', type: 'ewallet'),
  (provider: 'dana', name: 'DANA', type: 'ewallet'),
  (provider: 'ovo', name: 'OVO', type: 'ewallet'),
  (provider: 'shopeepay', name: 'ShopeePay', type: 'ewallet'),
  (provider: 'bca', name: 'BCA', type: 'bank'),
  (provider: 'bri', name: 'BRI', type: 'bank'),
  (provider: 'mandiri', name: 'Mandiri', type: 'bank'),
  (provider: 'bni', name: 'BNI', type: 'bank'),
  (provider: 'bsi', name: 'BSI', type: 'bank'),
  (provider: 'jago', name: 'Bank Jago', type: 'bank'),
  (provider: 'seabank', name: 'SeaBank', type: 'bank'),
  (provider: 'spaylater', name: 'SPayLater', type: 'paylater'),
  (provider: 'gopaylater', name: 'GoPayLater', type: 'paylater'),
  (provider: 'kredivo', name: 'Kredivo', type: 'paylater'),
];

class AccountsTab extends StatelessWidget {
  const AccountsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      // Balance is derived from records (never stored), so two phones can't disagree about it.
      stream: db.watch('''
        SELECT a.id, a.name, a.type, a.initial_balance + COALESCE(SUM(CASE
            WHEN r.account_id = a.id AND r.type = 'income' THEN r.amount
            WHEN r.account_id = a.id AND r.type IN ('expense', 'transfer') THEN -r.amount
            WHEN r.transfer_account_id = a.id THEN r.transfer_amount END), 0) AS balance
        FROM accounts a
        LEFT JOIN records r ON a.id IN (r.account_id, r.transfer_account_id) AND r.status = 'confirmed'
        WHERE a.archived = 0
        GROUP BY a.id ORDER BY a.name'''),
      builder: (context, snap) {
        final rows = snap.data;
        if (rows == null) return const Center(child: CircularProgressIndicator());
        if (rows.isEmpty) return const Center(child: Text('Belum ada akun. Tekan + untuk menambah.'));
        final total = rows.fold<int>(0, (sum, r) => sum + (r['balance'] as int));
        return ListView(
          children: [
            ListTile(
              title: const Text('Total saldo'),
              trailing: Text(formatAmount(total), style: Theme.of(context).textTheme.titleLarge),
            ),
            const Divider(),
            for (final r in rows)
              ListTile(
                title: Text(r['name'] as String),
                subtitle: Text(accountTypes[r['type']] ?? r['type'] as String),
                trailing: Text(formatAmount(r['balance'] as int)),
              ),
          ],
        );
      },
    );
  }
}

Future<void> showAccountForm(BuildContext context) =>
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => const AccountForm());

class AccountForm extends StatefulWidget {
  const AccountForm({super.key});

  @override
  State<AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends State<AccountForm> {
  final _name = TextEditingController();
  final _balance = TextEditingController();
  String _type = 'cash';
  String? _provider;

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return showMessage(context, 'Isi nama akun.');
    final raw = _balance.text.trim();
    final negative = raw.startsWith('-');
    final parsed = raw.isEmpty || raw == '0' ? 0 : parseAmount(raw.replaceFirst('-', ''));
    if (parsed == null) return showMessage(context, 'Saldo awal tidak valid.');
    final now = nowIso();
    await db.execute('''
      INSERT INTO accounts (id, user_id, name, type, provider, currency, initial_balance,
        archived, exclude_from_stats, created_at, updated_at)
      VALUES (uuid(), ?, ?, ?, ?, 'IDR', ?, 0, 0, ?, ?)''',
        [currentUserId, name, _type, _provider, negative ? -parsed : parsed, now, now]);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final p in accountPresets)
                ChoiceChip(
                  label: Text(p.name),
                  selected: _provider == p.provider,
                  onSelected: (_) => setState(() {
                    _provider = p.provider;
                    _type = p.type;
                    _name.text = p.name;
                  }),
                ),
            ],
          ),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Nama akun')),
          DropdownButtonFormField(
            key: ValueKey(_type),
            initialValue: _type,
            decoration: const InputDecoration(labelText: 'Jenis'),
            items: [for (final e in accountTypes.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setState(() => _type = v!),
          ),
          TextField(
            controller: _balance,
            keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
            decoration: const InputDecoration(
              labelText: 'Saldo awal',
              prefixText: 'Rp ',
              helperText: 'Untuk kartu kredit/paylater, isi utang sebagai minus, contoh -500.000',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Simpan')),
        ],
      ),
    );
  }
}
