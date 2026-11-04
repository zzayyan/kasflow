import 'package:flutter/material.dart';

import '../db.dart';
import '../money.dart';
import '../ui.dart';

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
      stream: db.watch('''
        SELECT a.id, a.name, a.type, b.balance
        FROM accounts a JOIN ($accountBalancesSql) b ON b.id = a.id
        WHERE a.archived = 0
        ORDER BY a.name'''),
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

/// The account list as its own page, opened from Beranda ("Akun saya").
class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Akun')),
      body: const AccountsTab(),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Tambah akun',
        onPressed: () => showAccountForm(context),
        child: const Icon(Icons.add),
      ),
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
