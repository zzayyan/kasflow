import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../money.dart';
import '../theme.dart';
import '../ui.dart';

// Kelola akun, after the "Kelola akun" artboard of the Cashflow UI/UX canvas.

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

// The list's sections, in the design's order.
const _groups = [
  ('Tunai dan e-wallet', {'cash', 'ewallet'}),
  ('Bank', {'bank'}),
  ('Tabungan dan investasi', {'savings', 'investment'}),
  ('Kredit dan pinjaman', {'credit_card', 'paylater', 'loan'}),
];

/// Two or three letters for an account's badge: "BCA", "GoPay" -> "GP", "DANA" -> "DA".
String accountInitials(String name) {
  final n = name.trim();
  if (n.isEmpty) return '?';
  if (n.length <= 3) return n.toUpperCase();
  final words = n.split(RegExp(r'\s+'));
  if (words.length > 1) return (words[0][0] + words[1][0]).toUpperCase();
  final capitals = n.replaceAll(RegExp(r'[^A-Z]'), '');
  return (capitals.length >= 2 ? capitals.substring(0, 2) : n.substring(0, 2)).toUpperCase();
}

/// The account list, opened from Beranda ("Akun") and Pengaturan.
class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key});

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  List<Map<String, dynamic>>? _rows;
  late final StreamSubscription<void> _sub;
  bool _showArchived = false;

  @override
  void initState() {
    super.initState();
    _sub = db
        .watch('''
          SELECT a.*, b.balance
          FROM accounts a JOIN ($accountBalancesSql) b ON b.id = a.id
          ORDER BY a.name COLLATE NOCASE''')
        .listen((rows) {
          if (mounted) setState(() => _rows = rows);
        });
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final rows = _rows;
    final active = rows?.where((a) => a['archived'] == 0).toList() ?? const [];
    final archived = rows?.where((a) => a['archived'] != 0).toList() ?? const [];
    final total = active.fold<int>(0, (sum, a) => sum + (a['balance'] as int));
    return Scaffold(
      appBar: pageAppBar(
        context,
        'Akun',
        action: AddButton(tooltip: 'Tambah akun', onPressed: () => showAccountForm(context)),
      ),
      body: rows == null
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 28),
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                  decoration: BoxDecoration(
                    color: c.hero,
                    borderRadius: BorderRadius.circular(AppRadius.hero),
                    border: Theme.of(context).brightness == Brightness.dark ? Border.all(color: c.heroChip) : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total saldo · ${active.length} akun',
                        style: AppText.label.copyWith(color: c.onHeroMuted),
                      ),
                      const SizedBox(height: 6),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text('Rp', style: AppText.body.copyWith(fontSize: 16, color: c.onHeroMuted)),
                            const SizedBox(width: 6),
                            Text(
                              NumberFormat.decimalPattern('id_ID').format(total / 100).replaceFirst('-', '−'),
                              style: AppText.amountLg.copyWith(fontSize: 32, height: 1, color: c.onHero),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (active.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      'Belum ada akun. Tekan + untuk menambah dompet, bank, atau e-wallet.',
                      textAlign: TextAlign.center,
                      style: AppText.body.copyWith(color: c.inkMuted),
                    ),
                  ),
                for (final (title, types) in _groups)
                  if (active.where((a) => types.contains(a['type'])).toList() case final group when group.isNotEmpty)
                    _Group(title: title, accounts: group),
                if (archived.isNotEmpty) ...[
                  const SizedBox(height: AppSpace.section),
                  TextButton(
                    onPressed: () => setState(() => _showArchived = !_showArchived),
                    style: TextButton.styleFrom(foregroundColor: c.inkMuted, textStyle: AppText.label.copyWith(fontSize: 14)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Diarsipkan (${archived.length})'),
                        const SizedBox(width: 6),
                        Icon(_showArchived ? Icons.expand_less : Icons.expand_more, size: 16),
                      ],
                    ),
                  ),
                  if (_showArchived) _Group(title: 'Diarsipkan', accounts: archived, showTotal: false),
                ],
              ],
            ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.accounts, this.showTotal = true});

  final String title;
  final List<Map<String, dynamic>> accounts;
  final bool showTotal;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final total = accounts.fold<int>(0, (sum, a) => sum + (a['balance'] as int));
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(
              children: [
                Expanded(child: Text(title, style: AppText.label.copyWith(color: c.inkMuted))),
                if (showTotal)
                  Text(
                    formatAmount(total).replaceFirst('-', '−'),
                    style: AppText.label.copyWith(color: c.inkMuted),
                  ),
              ],
            ),
          ),
          Material(
            color: c.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  for (final (i, a) in accounts.indexed) ...[
                    if (i > 0) const Divider(indent: 16, endIndent: 16),
                    _AccountRow(a),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow(this.a);

  final Map<String, dynamic> a;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final type = a['type'] as String;
    final name = a['name'] as String;
    final excluded = a['exclude_from_stats'] != 0;
    // Banks get the dark badge, wallets the soft one; cash and savings an icon instead of letters.
    final (bg, fg) = switch (type) {
      'bank' => (c.hero, c.onHero),
      'ewallet' || 'paylater' => (c.primarySoft, c.primary),
      _ => (c.surfaceMuted, c.ink),
    };
    final icon = switch (type) {
      'cash' => Icons.payments_outlined,
      'savings' => Icons.track_changes,
      'investment' => Icons.trending_up,
      _ => null,
    };
    return InkWell(
      onTap: () => showAccountForm(context, account: a),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                child: icon != null
                    ? Icon(icon, size: 20, color: fg)
                    : Text(
                        accountInitials(name),
                        style: AppText.caption.copyWith(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
                      ),
              ),
              const SizedBox(width: AppSpace.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 3),
                    if (excluded)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: c.surfaceMuted, borderRadius: BorderRadius.circular(8)),
                        child: Text('Tidak masuk laporan', style: AppText.caption.copyWith(fontSize: 11)),
                      )
                    else
                      Text(accountTypes[type] ?? type, style: AppText.caption.copyWith(color: c.inkMuted)),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.gap),
              Text(
                formatAmount(a['balance'] as int).replaceFirst('-', '−'),
                style: AppText.amount,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// New account, or [account] (a row of `accounts`) to edit.
Future<void> showAccountForm(BuildContext context, {Map<String, dynamic>? account}) => showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  builder: (_) => AccountForm(account: account),
);

class AccountForm extends StatefulWidget {
  const AccountForm({super.key, this.account});

  final Map<String, dynamic>? account;

  @override
  State<AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends State<AccountForm> {
  late final _a = widget.account;
  late final _name = TextEditingController(text: _a?['name'] as String?);
  late final _balance = TextEditingController(
    text: _a == null ? null : NumberFormat.decimalPattern('id_ID').format((_a['initial_balance'] as int) / 100),
  );
  late String _type = (_a?['type'] as String?) ?? 'cash';
  late String? _provider = _a?['provider'] as String?;
  late bool _inReports = (_a?['exclude_from_stats'] ?? 0) == 0;

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return showMessage(context, 'Isi nama akun.');
    final raw = _balance.text.trim();
    final negative = raw.startsWith('-');
    final parsed = raw.isEmpty || raw == '0' ? 0 : parseAmount(raw.replaceFirst('-', ''));
    if (parsed == null) return showMessage(context, 'Saldo awal tidak valid.');
    final initial = negative ? -parsed : parsed;
    final now = nowIso();
    if (_a == null) {
      await db.execute(
        '''
        INSERT INTO accounts (id, user_id, name, type, provider, currency, initial_balance,
          archived, exclude_from_stats, created_at, updated_at)
        VALUES (uuid(), ?, ?, ?, ?, 'IDR', ?, 0, ?, ?, ?)''',
        [currentUserId, name, _type, _provider, initial, _inReports ? 0 : 1, now, now],
      );
    } else {
      await db.execute(
        '''
        UPDATE accounts SET name = ?, type = ?, initial_balance = ?, exclude_from_stats = ?, updated_at = ?
        WHERE id = ?''',
        [name, _type, initial, _inReports ? 0 : 1, now, _a['id']],
      );
    }
    if (mounted) Navigator.pop(context);
  }

  /// Archived accounts leave every list and total but keep their records, so history stays whole.
  Future<void> _toggleArchive() async {
    await db.execute('UPDATE accounts SET archived = ?, updated_at = ? WHERE id = ?', [
      _a!['archived'] == 0 ? 1 : 0,
      nowIso(),
      _a['id'],
    ]);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final archived = _a != null && _a['archived'] != 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, MediaQuery.viewInsetsOf(context).bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_a == null ? 'Akun baru' : 'Ubah akun', style: AppText.heading),
            const SizedBox(height: AppSpace.gap),
            if (_a == null) ...[
              Wrap(
                spacing: AppSpace.tight,
                runSpacing: AppSpace.tight,
                children: [
                  for (final p in accountPresets)
                    ChoiceChip(
                      label: Text(p.name),
                      selected: _provider == p.provider,
                      showCheckmark: false,
                      labelStyle: AppText.label.copyWith(
                        fontSize: 14,
                        color: _provider == p.provider ? c.onPrimary : c.ink,
                      ),
                      onSelected: (_) => setState(() {
                        _provider = p.provider;
                        _type = p.type;
                        _name.text = p.name;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Nama akun')),
            const SizedBox(height: AppSpace.gap),
            DropdownButtonFormField(
              key: ValueKey(_type),
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'Jenis'),
              style: AppText.body.copyWith(color: c.ink),
              items: [for (final e in accountTypes.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => setState(() => _type = v!),
            ),
            const SizedBox(height: AppSpace.gap),
            TextField(
              controller: _balance,
              keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
              inputFormatters: const [AmountInputFormatter()],
              decoration: const InputDecoration(
                labelText: 'Saldo awal',
                prefixText: 'Rp ',
                helperText: 'Untuk kartu kredit/paylater, isi utang sebagai minus, contoh -500.000',
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Hitung di laporan', style: AppText.body),
              subtitle: Text(
                'Matikan untuk tabungan atau dana yang tidak dipakai sehari-hari.',
                style: AppText.caption.copyWith(color: c.inkMuted),
              ),
              value: _inReports,
              onChanged: (v) => setState(() => _inReports = v),
            ),
            const SizedBox(height: AppSpace.gap),
            Row(
              children: [
                if (_a != null) ...[
                  OutlinedButton(
                    onPressed: _toggleArchive,
                    style: OutlinedButton.styleFrom(minimumSize: const Size(64, 56)),
                    child: Text(archived ? 'Pulihkan' : 'Arsipkan'),
                  ),
                  const SizedBox(width: AppSpace.gap),
                ],
                Expanded(
                  child: FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                    child: const Text('Simpan'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
