import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'categorize.dart';
import 'db.dart';
import 'insights.dart';
import 'money.dart';
import 'notifications.dart';
import 'quick_input.dart';

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
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true, brightness: Brightness.dark),
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
        title: Text(const ['Transaksi', 'Akun', 'Budget', 'Laporan'][_tab]),
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
      body: const [RecordsTab(), AccountsTab(), BudgetsTab(), ReportTab()][_tab],
      floatingActionButton: _tab == 3
          ? null // the report has nothing to add
          : FloatingActionButton(
              onPressed: () => [showRecordForm, showAccountForm, showBudgetForm][_tab](context),
              child: const Icon(Icons.add),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Transaksi'),
          NavigationDestination(icon: Icon(Icons.account_balance_wallet), label: 'Akun'),
          NavigationDestination(icon: Icon(Icons.savings_outlined), label: 'Budget'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Laporan'),
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
    return Column(
      children: [
        const QuickInputBar(),
        const NotificationInbox(),
        Expanded(child: _records()),
      ],
    );
  }

  Widget _records() {
    return StreamBuilder(
      // ponytail: newest 500 only; add paging when a user has more history than that.
      stream: db.watch('''
        SELECT r.*, a.name AS account_name, t.name AS target_name, c.name AS category_name
        FROM records r
        LEFT JOIN accounts a ON a.id = r.account_id
        LEFT JOIN accounts t ON t.id = r.transfer_account_id
        LEFT JOIN categories c ON c.id = r.category_id
        ORDER BY julianday(r.occurred_at) DESC LIMIT 500'''),
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
                '${type == 'income'
                    ? '+'
                    : type == 'expense'
                    ? '-'
                    : ''}${formatAmount(amount)}',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: type == 'income'
                      ? Colors.green.shade700
                      : type == 'expense'
                      ? Colors.red.shade700
                      : null,
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

/// Values to start the record form with, from a detected notification or from quick input.
class Prefill {
  const Prefill({
    this.amount,
    this.type,
    this.accountId,
    this.provider,
    this.categoryId,
    this.note,
    this.date,
    this.guessText,
    this.source = 'manual',
    this.sourceRef,
    this.inboxId,
  });

  final int? amount;
  final String? type;
  final String? accountId;
  final String? provider; // picks the account with this preset when accountId is null
  final String? categoryId;
  final String? note;
  final DateTime? date;
  final String? guessText; // text to guess the category from when categoryId is null
  final String source;
  final String? sourceRef;
  final String? inboxId; // inbox row to remove once the record is saved
}

Future<void> showRecordForm(BuildContext context, {Prefill? prefill}) async {
  final accounts = await db.getAll(
    'SELECT id, name, currency, provider FROM accounts WHERE archived = 0 ORDER BY name',
  );
  if (!context.mounted) return;
  if (accounts.isEmpty) {
    showMessage(context, 'Buat akun dulu di tab Akun.');
    return;
  }
  final categories = await db.getAll(
    'SELECT id, name, type, keywords FROM categories WHERE archived = 0 ORDER BY name',
  );
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => RecordForm(accounts: accounts, categories: categories, prefill: prefill),
  );
}

class RecordForm extends StatefulWidget {
  const RecordForm({super.key, required this.accounts, required this.categories, this.prefill});

  final List<Map<String, dynamic>> accounts;
  final List<Map<String, dynamic>> categories;
  final Prefill? prefill;

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

  @override
  void initState() {
    super.initState();
    final p = widget.prefill;
    if (p == null) return;
    if (p.amount != null) _amount.text = NumberFormat.decimalPattern('id_ID').format(p.amount! / 100);
    _type = p.type ?? 'expense';
    _note.text = p.note ?? '';
    _date = p.date ?? _date;
    final account = widget.accounts
        .where((a) => p.accountId != null ? a['id'] == p.accountId : p.provider != null && a['provider'] == p.provider)
        .firstOrNull;
    if (account != null) _accountId = account['id'] as String;
    _categoryId = p.categoryId ?? guessCategoryId(p.guessText ?? _note.text, _type, widget.categories);
  }

  // Typing a note fills an empty category, e.g. "bakso" -> Makan & Minum. Never overrides a choice.
  bool _categoryPicked = false;

  void _onNoteChanged(String note) {
    if (_categoryPicked || _type == 'transfer') return;
    final guess = guessCategoryId(note, _type, widget.categories);
    if (guess != _categoryId) setState(() => _categoryId = guess);
  }

  Future<void> _save() async {
    final amount = parseAmount(_amount.text);
    if (amount == null) return showMessage(context, 'Nominal tidak valid. Contoh: 25.000 atau 25rb');
    if (_type == 'transfer' && (_targetId == null || _targetId == _accountId)) {
      return showMessage(context, 'Pilih akun tujuan yang berbeda.');
    }
    final currency = widget.accounts.firstWhere((a) => a['id'] == _accountId)['currency'] as String;
    final p = widget.prefill;
    final note = _note.text.trim();
    final transfer = _type == 'transfer';
    await insertRecord(
      accountId: _accountId,
      type: _type,
      amount: amount,
      currency: currency,
      occurredAt: _date,
      categoryId: transfer ? null : _categoryId,
      transferAccountId: transfer ? _targetId : null,
      // ponytail: same-currency transfers only; ask for the received amount when currencies differ.
      transferAmount: transfer ? amount : null,
      note: note.isEmpty ? null : note,
      source: p?.source ?? 'manual',
      sourceRef: p?.sourceRef,
      inboxId: p?.inboxId,
    );
    // Learn only from notes the user typed: a notification title like "Pembayaran berhasil" says nothing
    // about the category. Skip when the keywords already led to this category.
    final picked = _categoryId;
    if (_categoryPicked && picked != null && p?.inboxId == null && note.isNotEmpty) {
      if (guessCategoryId(note, _type, widget.categories) != picked) await learnKeyword(note, picked);
    }
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
              _categoryPicked = false;
              _categoryId = _type == 'transfer' ? null : guessCategoryId(_note.text, _type, widget.categories);
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
              key: ValueKey('$_type/$_categoryId'), // rebuild when the type or the guessed category changes
              initialValue: _categoryId,
              decoration: const InputDecoration(labelText: 'Kategori'),
              items: [
                for (final c in categories)
                  DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String)),
              ],
              onChanged: (v) => setState(() {
                _categoryId = v;
                _categoryPicked = true;
              }),
            ),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
              labelText: 'Catatan (opsional)',
              hintText: 'contoh: bakso, bensin, token PLN',
            ),
            onChanged: _onNoteChanged,
          ),
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

// ---------------------------------------------------------------- quick input (B2)

class QuickInputBar extends StatefulWidget {
  const QuickInputBar({super.key});

  @override
  State<QuickInputBar> createState() => _QuickInputBarState();
}

class _QuickInputBarState extends State<QuickInputBar> {
  final _text = TextEditingController();

  Future<void> _submit() async {
    final input = _text.text.trim();
    if (input.isEmpty) return;
    final accounts = await db.getAll('SELECT id, name, provider, currency FROM accounts WHERE archived = 0');
    final categories = await db.getAll('SELECT id, name, type, keywords FROM categories WHERE archived = 0');
    if (!mounted) return;
    if (accounts.isEmpty) return showMessage(context, 'Buat akun dulu di tab Akun.');
    final entry = parseQuickInput(input, accounts: accounts, categories: categories);
    if (entry == null) return showMessage(context, 'Nominal tidak ditemukan. Contoh: bakso 25rb pakai dana');

    // No account named: use the one from the latest record, so a daily wallet needs no typing.
    final last = await db.getOptional('SELECT account_id FROM records ORDER BY created_at DESC LIMIT 1');
    final accountId =
        entry.accountId ??
        accounts.map((a) => a['id'] as String).where((id) => id == last?['account_id']).firstOrNull ??
        accounts.first['id'] as String;
    _text.clear();
    if (!mounted) return;

    if (entry.categoryId == null) {
      // Unknown words: let the user pick, which also teaches the keyword for next time.
      return showRecordForm(
        context,
        prefill: Prefill(
          amount: entry.amount,
          type: entry.type,
          accountId: accountId,
          note: entry.note,
          date: entry.date,
          source: 'nlp',
        ),
      );
    }
    final account = accounts.firstWhere((a) => a['id'] == accountId);
    final id = await insertRecord(
      accountId: accountId,
      type: entry.type,
      amount: entry.amount,
      currency: account['currency'] as String,
      occurredAt: entry.date,
      categoryId: entry.categoryId,
      note: entry.note.isEmpty ? null : entry.note,
      source: 'nlp',
    );
    if (!mounted) return;
    final category = categories.firstWhere((c) => c['id'] == entry.categoryId)['name'];
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Tersimpan: $category · ${formatAmount(entry.amount)} · ${account['name']}'),
        action: SnackBarAction(
          label: 'Batalkan',
          onPressed: () => db.execute('DELETE FROM records WHERE id = ?', [id]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: TextField(
        controller: _text,
        textInputAction: TextInputAction.send,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          hintText: 'Catat cepat: bakso 25rb pakai dana',
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: IconButton(icon: const Icon(Icons.send), tooltip: 'Simpan', onPressed: _submit),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- notification inbox (B1)

class NotificationInbox extends StatefulWidget {
  const NotificationInbox({super.key});

  @override
  State<NotificationInbox> createState() => _NotificationInboxState();
}

class _NotificationInboxState extends State<NotificationInbox> with WidgetsBindingObserver {
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Returning from Android settings or from a bank app both arrive here.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final enabled = await notificationAccessEnabled();
    if (mounted) setState(() => _enabled = enabled);
    if (enabled) await importNotifications();
  }

  @override
  Widget build(BuildContext context) {
    if (_enabled == null) return const SizedBox.shrink();
    if (_enabled == false) {
      return Card(
        margin: const EdgeInsets.all(12),
        child: ListTile(
          leading: const Icon(Icons.notifications_active),
          title: const Text('Catat otomatis dari notifikasi bank & e-wallet'),
          subtitle: const Text('Hanya notifikasi aplikasi keuangan yang dibaca. Isinya tetap di HP ini.'),
          trailing: FilledButton(onPressed: openNotificationAccessSettings, child: const Text('Aktifkan')),
        ),
      );
    }
    return StreamBuilder(
      stream: db.watch('SELECT * FROM inbox ORDER BY posted_at DESC'),
      builder: (context, snap) {
        final rows = snap.data;
        if (rows == null || rows.isEmpty) return const SizedBox.shrink();
        return Card(
          margin: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text('Perlu dicek (${rows.length})', style: Theme.of(context).textTheme.titleSmall),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView(shrinkWrap: true, children: [for (final n in rows) _item(context, n)]),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _item(BuildContext context, Map<String, dynamic> n) {
    final provider = accountPresets.where((p) => p.provider == n['provider']).map((p) => p.name).firstOrNull;
    final type = n['type'] as String?;
    return ListTile(
      leading: Icon(
        type == 'income'
            ? Icons.south_west
            : type == 'expense'
            ? Icons.north_east
            : Icons.help_outline,
        color: type == 'income'
            ? Colors.green.shade700
            : type == 'expense'
            ? Colors.red.shade700
            : null,
      ),
      title: Text('${provider ?? n['package']} · ${formatAmount(n['amount'] as int)}'),
      subtitle: Text(n['text'] as String, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Abaikan',
        onPressed: () => db.execute('DELETE FROM inbox WHERE id = ?', [n['id']]),
      ),
      onTap: () => showRecordForm(
        context,
        prefill: Prefill(
          amount: n['amount'] as int,
          type: type,
          provider: n['provider'] as String?,
          note: n['title'] as String?,
          date: DateTime.parse(n['posted_at'] as String).toLocal(),
          guessText: '${n['title'] ?? ''}\n${n['text']}',
          source: 'notification',
          sourceRef: n['ref'] as String, // server-side unique index stops the same notification being recorded twice
          inboxId: n['id'] as String,
        ),
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
    await db.execute(
      '''
      INSERT INTO accounts (id, user_id, name, type, provider, currency, initial_balance,
        archived, exclude_from_stats, created_at, updated_at)
      VALUES (uuid(), ?, ?, ?, ?, 'IDR', ?, 0, 0, ?, ?)''',
      [currentUserId, name, _type, _provider, negative ? -parsed : parsed, now, now],
    );
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
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Nama akun'),
          ),
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
