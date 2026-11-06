import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../db.dart';
import '../money.dart';
import '../theme.dart';
import '../ui.dart';
import 'report_tab.dart';

// A4: labels (free tags on records), e.g. "liburan bali" or "kantor".

/// Compares label names the way people type hashtags: case, spaces, "-" and "_" don't matter,
/// so #liburan-bali, #LiburanBali and "liburan bali" are the same label.
String labelKey(String name) => name.toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');

/// Label ids for [names] (from hashtags), creating the labels that don't exist yet.
Future<List<String>> resolveLabelIds(List<String> names) async {
  if (names.isEmpty) return const [];
  return db.writeTransaction((tx) async {
    final existing = {
      for (final l in await tx.getAll('SELECT id, name FROM labels')) labelKey(l['name'] as String): l['id'] as String,
    };
    final ids = <String>[];
    for (final name in names) {
      var id = existing[labelKey(name)];
      if (id == null) {
        id = (await tx.get('SELECT uuid() AS id'))['id'] as String;
        final now = nowIso();
        await tx.execute('INSERT INTO labels (id, user_id, name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)', [
          id,
          currentUserId,
          name,
          now,
          now,
        ]);
        existing[labelKey(name)] = id;
      }
      if (!ids.contains(id)) ids.add(id);
    }
    return ids;
  });
}

List<String> labelIdsOf(Object? json) =>
    json is String && json.isNotEmpty ? (jsonDecode(json) as List).cast<String>() : <String>[];

Future<String?> _askLabelName(BuildContext context, {String? initial, String title = 'Label baru'}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'contoh: liburan bali'),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Simpan')),
      ],
    ),
  );
}

/// Selectable label chips with a "+ Label" chip that creates a label on the spot.
class LabelChips extends StatefulWidget {
  const LabelChips({super.key, required this.labels, required this.selected, required this.onChanged});

  final List<Map<String, dynamic>> labels; // id, name
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  State<LabelChips> createState() => _LabelChipsState();
}

class _LabelChipsState extends State<LabelChips> {
  late final _labels = [...widget.labels];
  late final _selected = {...widget.selected};

  void _toggle(String id, bool on) {
    setState(() => on ? _selected.add(id) : _selected.remove(id));
    widget.onChanged({..._selected});
  }

  Future<void> _create() async {
    final name = await _askLabelName(context);
    if (name == null || name.isEmpty) return;
    final id = (await resolveLabelIds([name])).first;
    if (!_labels.any((l) => l['id'] == id)) _labels.add({'id': id, 'name': name});
    _toggle(id, true);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final l in _labels)
          FilterChip(
            label: Text('#${l['name']}'),
            selected: _selected.contains(l['id']),
            onSelected: (on) => _toggle(l['id'] as String, on),
          ),
        ActionChip(avatar: const Icon(Icons.add, size: 18), label: const Text('Label'), onPressed: _create),
      ],
    );
  }
}

/// Colors a label can have (labels.color), as in the design: identity only, the name is always shown.
const labelColors = [
  (Color(0xFF1E4A35), 'Hijau tua'),
  (Color(0xFF7FAF8C), 'Sage'),
  (Color(0xFF5B7A99), 'Biru batu'),
  (Color(0xFF8C6A8F), 'Ungu'),
  (Color(0xFF9A8F7A), 'Pasir'),
];

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

Color? _parseHex(Object? hex) =>
    hex is String && hex.length == 7 ? Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000) : null;

/// Kelola label, after the "Kelola label" artboard of the Cashflow UI/UX canvas.
class LabelsPage extends StatefulWidget {
  const LabelsPage({super.key});

  @override
  State<LabelsPage> createState() => _LabelsPageState();
}

class _LabelsPageState extends State<LabelsPage> {
  final _name = TextEditingController();
  Color _color = labelColors.first.$1;
  List<Map<String, dynamic>>? _rows;
  late final StreamSubscription<void> _sub;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final start = DateTime(now.year, now.month).toUtc().toIso8601String();
    final end = DateTime(now.year, now.month + 1).toUtc().toIso8601String();
    // This month's use of each label: how many records, and what was spent.
    _sub = db
        .watch(
          '''
          SELECT l.id, l.name, l.color,
            COUNT(r.id) AS n,
            COALESCE(SUM(CASE WHEN r.type = 'expense' THEN r.amount END), 0) AS spent
          FROM labels l
          LEFT JOIN (
            SELECT r.id, r.type, r.amount, j.value AS label_id
            FROM records r, json_each(r.label_ids) j
            WHERE r.status = 'confirmed'
              AND julianday(r.occurred_at) >= julianday(?1) AND julianday(r.occurred_at) < julianday(?2)
          ) r ON r.label_id = l.id
          GROUP BY l.id
          ORDER BY l.name COLLATE NOCASE''',
          parameters: [start, end],
          triggerOnTables: const ['labels', 'records'],
        )
        .listen((rows) {
          if (mounted) setState(() => _rows = rows);
        });
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    _name.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _name.text.trim().replaceFirst(RegExp(r'^#'), '');
    if (name.isEmpty) return;
    if (_rows?.any((l) => labelKey(l['name'] as String) == labelKey(name)) ?? false) {
      return showMessage(context, 'Label #$name sudah ada.');
    }
    final id = (await resolveLabelIds([name])).first;
    await db.execute('UPDATE labels SET color = ?, updated_at = ? WHERE id = ?', [_hex(_color), nowIso(), id]);
    _name.clear();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final rows = _rows;
    return Scaffold(
      appBar: pageAppBar(context, 'Label'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 28),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(
                    text: 'Label mengelompokkan transaksi lintas kategori, misalnya semua pengeluaran liburan. Ketik ',
                  ),
                  TextSpan(text: '#liburan', style: TextStyle(fontWeight: FontWeight.w600, color: c.ink)),
                  const TextSpan(text: ' saat catat cepat.'),
                ],
              ),
              style: AppText.label.copyWith(fontSize: 14, color: c.inkMuted, height: 1.45),
            ),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 4, right: 8),
                      child: Text('#', style: AppText.heading.copyWith(fontSize: 18, color: c.inkMuted)),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _name,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _add(),
                        style: AppText.body.copyWith(fontSize: 16),
                        decoration: const InputDecoration(
                          hintText: 'nama label baru',
                          filled: false,
                          isCollapsed: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 12),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                      ),
                    ),
                    FilledButton(
                      onPressed: _add,
                      style: FilledButton.styleFrom(minimumSize: const Size(64, 44), textStyle: AppText.label),
                      child: const Text('Tambah'),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.gap),
                Row(
                  children: [
                    for (final (color, name) in labelColors)
                      Semantics(
                        selected: color == _color,
                        child: IconButton(
                          tooltip: name,
                          onPressed: () => setState(() => _color = color),
                          style: IconButton.styleFrom(
                            fixedSize: const Size.square(44),
                            side: BorderSide(color: color == _color ? c.ink : Colors.transparent, width: 2),
                          ),
                          icon: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (rows != null && rows.isNotEmpty) ...[
            Material(
              color: c.surface,
              borderRadius: BorderRadius.circular(AppRadius.card),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    for (final (i, l) in rows.indexed) ...[
                      if (i > 0) const Divider(indent: 16, endIndent: 16),
                      _LabelRow(l, onOptions: () => _options(l)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Ketuk label untuk melihat laporannya. Tekan lama untuk ganti nama atau hapus.',
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: c.inkMuted, height: 1.4),
            ),
          ] else if (rows != null)
            Text(
              'Belum ada label. Tambahkan di atas, dari form transaksi, '
              'atau ketik tagar di catat cepat: "nasi padang 35rb #liburan".',
              textAlign: TextAlign.center,
              style: AppText.label.copyWith(color: c.inkMuted, height: 1.4),
            ),
        ],
      ),
    );
  }

  Future<void> _options(Map<String, dynamic> l) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Ganti nama'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Hapus label'),
              subtitle: const Text('Transaksinya tetap ada, hanya labelnya yang hilang'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'rename') {
      final name = await _askLabelName(context, initial: l['name'] as String, title: 'Ganti nama label');
      if (name == null || name.isEmpty) return;
      await db.execute('UPDATE labels SET name = ?, updated_at = ? WHERE id = ?', [name, nowIso(), l['id']]);
    } else if (choice == 'delete') {
      // ponytail: records keep the deleted id in label_ids; every view joins on labels, so it no longer
      // shows. Strip it from records if those ids ever matter (it costs one upload per record).
      await db.execute('DELETE FROM labels WHERE id = ?', [l['id']]);
    }
  }
}

class _LabelRow extends StatelessWidget {
  const _LabelRow(this.l, {required this.onOptions});

  final Map<String, dynamic> l;
  final VoidCallback onOptions;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final n = l['n'] as int;
    final spent = l['spent'] as int;
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => Scaffold(body: ReportTab(labelId: l['id'] as String))),
      ),
      onLongPress: () {
        haptic(Haptic.click);
        onOptions();
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: _parseHex(l['color']) ?? c.outline, shape: BoxShape.circle),
              ),
              const SizedBox(width: AppSpace.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('#${l['name']}', style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      n == 0 ? 'Belum dipakai bulan ini' : '$n transaksi bulan ini',
                      style: AppText.caption.copyWith(color: c.inkMuted),
                    ),
                  ],
                ),
              ),
              if (spent > 0) ...[
                const SizedBox(width: 8),
                Text(formatAmount(spent), style: AppText.amount.copyWith(fontSize: 14)),
              ],
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: c.inkMuted),
            ],
          ),
        ),
      ),
    );
  }
}
