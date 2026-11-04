import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../money.dart';
import '../notifications.dart';
import '../quick_input.dart';
import '../ui.dart';
import 'accounts_tab.dart';
import 'labels_page.dart';
import 'record_form.dart';

// A1 record list, B2 quick input and B1 notification inbox: the Transaksi tab.

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
        SELECT r.*, a.name AS account_name, t.name AS target_name, c.name AS category_name,
          (SELECT group_concat('#' || l.name, ' ') FROM json_each(r.label_ids) j JOIN labels l ON l.id = j.value)
            AS label_names
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
              ?r['label_names'],
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
              onTap: () => showRecordForm(context, prefill: Prefill.fromRecord(r)),
              onLongPress: () => confirmDeleteRecord(context, r['id'] as String),
            );
          },
        );
      },
    );
  }
}

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
    if (accounts.isEmpty) return showMessage(context, 'Buat akun dulu lewat Beranda, tombol Akun saya.');
    final entry = parseQuickInput(input, accounts: accounts, categories: categories);
    if (entry == null) return showMessage(context, 'Nominal tidak ditemukan. Contoh: bakso 25rb pakai dana');

    // No account named: use the one from the latest record, so a daily wallet needs no typing.
    final last = await db.getOptional('SELECT account_id FROM records ORDER BY created_at DESC LIMIT 1');
    final accountId =
        entry.accountId ??
        accounts.map((a) => a['id'] as String).where((id) => id == last?['account_id']).firstOrNull ??
        accounts.first['id'] as String;
    final labelIds = await resolveLabelIds(entry.labels); // "#liburan" creates the label if needed
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
          labelIds: labelIds,
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
      labelIds: labelIds,
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
