import 'dart:convert';

import 'package:flutter/material.dart';

import 'db.dart';

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

class LabelsPage extends StatelessWidget {
  const LabelsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('Kelola label')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Label baru',
        onPressed: () async {
          final name = await _askLabelName(context);
          if (name != null && name.isNotEmpty) await resolveLabelIds([name]);
        },
        child: const Icon(Icons.add),
      ),
      body: StreamBuilder(
        stream: db.watch('''
          SELECT l.id, l.name,
            (SELECT count(*) FROM records r, json_each(r.label_ids) j WHERE j.value = l.id) AS used
          FROM labels l ORDER BY l.name COLLATE NOCASE'''),
        builder: (context, snap) {
          final rows = snap.data;
          if (rows == null) return const Center(child: CircularProgressIndicator());
          if (rows.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Belum ada label. Tambahkan dari sini, dari form transaksi, '
                  'atau ketik tagar di catat cepat: "nasi padang 35rb #liburan".',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            children: [
              for (final l in rows)
                ListTile(
                  leading: const Icon(Icons.sell_outlined),
                  title: Text('#${l['name']}'),
                  trailing: Text('${l['used']} transaksi', style: TextStyle(color: muted, fontSize: 12)),
                  onTap: () => _edit(context, l),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _edit(BuildContext context, Map<String, dynamic> l) async {
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
    if (!context.mounted) return;
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
