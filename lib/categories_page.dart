import 'dart:convert';

import 'package:flutter/material.dart';

import 'categorize.dart';
import 'db.dart';
import 'insights.dart' show needLevelLabels;

// A3: manage categories (name, wajib/butuh/ingin level, keywords, archive).
// ponytail: flat list only; parent_id is in the schema for sub-categories when they are needed.

List<String> _keywordsOf(Map<String, dynamic> c) {
  final raw = c['keywords'];
  return raw is String && raw.isNotEmpty ? (jsonDecode(raw) as List).cast<String>() : <String>[];
}

class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key});

  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  String _type = 'expense';
  late Stream<List<Map<String, dynamic>>> _rows = _watch();

  // `used` counts what points at the category: records and bills. Unused ones can be deleted;
  // used ones are archived instead, so history keeps its categories.
  Stream<List<Map<String, dynamic>>> _watch() => db
      .watch(
        '''
        SELECT c.*,
          (SELECT count(*) FROM records r WHERE r.category_id = c.id)
            + (SELECT count(*) FROM planned_payments p WHERE p.category_id = c.id) AS used
        FROM categories c WHERE c.type = ?
        ORDER BY c.archived, c.name COLLATE NOCASE''',
        parameters: [_type],
      )
      .map((rows) => rows.toList());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kelola kategori')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Kategori baru',
        onPressed: () => showCategoryForm(context, type: _type),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton(
              segments: const [
                ButtonSegment(value: 'expense', label: Text('Pengeluaran')),
                ButtonSegment(value: 'income', label: Text('Pemasukan')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() {
                _type = s.first;
                _rows = _watch();
              }),
            ),
          ),
          Expanded(
            child: StreamBuilder(
              stream: _rows,
              builder: (context, snap) {
                final rows = snap.data;
                if (rows == null) return const Center(child: CircularProgressIndicator());
                final active = rows.where((c) => c['archived'] == 0).toList();
                final archived = rows.where((c) => c['archived'] != 0).toList();
                final muted = Theme.of(context).colorScheme.onSurfaceVariant;
                return ListView(
                  padding: const EdgeInsets.only(bottom: 88),
                  children: [
                    for (final c in active) _CategoryTile(c),
                    if (archived.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text(
                          'Diarsipkan',
                          style: TextStyle(color: muted, fontWeight: FontWeight.w600),
                        ),
                      ),
                      for (final c in archived) _CategoryTile(c),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile(this.c);

  final Map<String, dynamic> c;

  @override
  Widget build(BuildContext context) {
    final keywords = _keywordsOf(c);
    final used = c['used'] as int;
    final subtitle = [
      if (c['type'] == 'expense') needLevelLabels[c['need_level']]!,
      if (keywords.isNotEmpty)
        keywords.length <= 4 ? keywords.join(', ') : '${keywords.take(4).join(', ')} +${keywords.length - 4}'
      else
        'tanpa kata kunci',
    ].join(' · ');
    final archived = c['archived'] != 0;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return ListTile(
      title: Text(c['name'] as String, style: archived ? TextStyle(color: muted) : null),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(used == 0 ? 'belum dipakai' : '$used dipakai', style: TextStyle(color: muted, fontSize: 12)),
      onTap: () => showCategoryForm(context, type: c['type'] as String, category: c),
    );
  }
}

Future<void> showCategoryForm(BuildContext context, {required String type, Map<String, dynamic>? category}) async {
  final siblings = await db.getAll('SELECT id, name, keywords FROM categories WHERE type = ?', [type]);
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => CategoryForm(type: type, category: category, siblings: siblings),
  );
}

class CategoryForm extends StatefulWidget {
  const CategoryForm({super.key, required this.type, required this.siblings, this.category});

  final String type;
  final Map<String, dynamic>? category; // null = new
  final List<Map<String, dynamic>> siblings; // every category of this type, for duplicates and keyword owners

  @override
  State<CategoryForm> createState() => _CategoryFormState();
}

class _CategoryFormState extends State<CategoryForm> {
  late final _name = TextEditingController(text: widget.category?['name'] as String?);
  final _keywordInput = TextEditingController();
  late String _level = (widget.category?['need_level'] as String?) ?? '';
  late final List<String> _keywords = widget.category == null ? [] : _keywordsOf(widget.category!);
  String? _notice;

  String? get _id => widget.category?['id'] as String?;

  // Who owns each keyword now, among the other categories of this type.
  late final Map<String, String> _owners = {
    for (final s in widget.siblings)
      if (s['id'] != _id)
        for (final k in _keywordsOf(s)) k: s['name'] as String,
  };

  void _addKeyword() {
    final k = normalizeKeyword(_keywordInput.text);
    _keywordInput.clear();
    if (k == null || _keywords.contains(k)) return;
    setState(() {
      _keywords.add(k);
      final owner = _owners[k];
      _notice = owner == null ? null : '"$k" akan dipindah dari $owner';
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return _message('Isi nama kategori.');
    final duplicate = widget.siblings.any(
      (s) => s['id'] != _id && (s['name'] as String).toLowerCase() == name.toLowerCase(),
    );
    if (duplicate) return _message('Kategori "$name" sudah ada.');
    if (_keywordInput.text.trim().isNotEmpty) _addKeyword(); // typed but not added yet
    await saveCategory(
      id: _id,
      name: name,
      type: widget.type,
      needLevel: widget.type == 'expense' && _level.isNotEmpty ? _level : null,
      keywords: _keywords,
    );
    if (mounted) Navigator.pop(context);
  }

  Future<void> _archiveOrDelete() async {
    final c = widget.category!;
    if ((c['used'] as int) == 0) {
      await db.execute('DELETE FROM categories WHERE id = ?', [_id]);
    } else {
      await db.execute('UPDATE categories SET archived = ?, updated_at = ? WHERE id = ?', [
        c['archived'] == 0 ? 1 : 0,
        nowIso(),
        _id,
      ]);
    }
    if (mounted) Navigator.pop(context);
  }

  void _message(String text) => setState(() => _notice = text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.category;
    final unused = c != null && (c['used'] as int) == 0;
    final archived = c != null && c['archived'] != 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${c == null ? 'Kategori baru' : 'Ubah kategori'} · ${widget.type == 'expense' ? 'pengeluaran' : 'pemasukan'}',
              style: theme.textTheme.titleMedium,
            ),
            TextField(
              controller: _name,
              autofocus: c == null,
              decoration: const InputDecoration(labelText: 'Nama'),
            ),
            if (widget.type == 'expense') ...[
              const SizedBox(height: 12),
              Text('Level', style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              SegmentedButton(
                segments: [
                  for (final level in const ['must', 'need', 'want', ''])
                    ButtonSegment(value: level, label: Text(level.isEmpty ? 'Tanpa' : needLevelLabels[level]!)),
                ],
                selected: {_level},
                onSelectionChanged: (s) => setState(() => _level = s.first),
              ),
            ],
            const SizedBox(height: 12),
            Text('Kata kunci untuk tebak kategori otomatis', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final k in _keywords)
                  InputChip(label: Text(k), onDeleted: () => setState(() => _keywords.remove(k))),
              ],
            ),
            TextField(
              controller: _keywordInput,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _addKeyword(),
              decoration: InputDecoration(
                hintText: 'contoh: mixue, indomaret',
                suffixIcon: IconButton(icon: const Icon(Icons.add), tooltip: 'Tambah', onPressed: _addKeyword),
              ),
            ),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_notice!, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (c != null)
                  TextButton.icon(
                    onPressed: _archiveOrDelete,
                    icon: Icon(
                      unused
                          ? Icons.delete_outline
                          : archived
                          ? Icons.unarchive_outlined
                          : Icons.archive_outlined,
                    ),
                    label: Text(
                      unused
                          ? 'Hapus'
                          : archived
                          ? 'Pulihkan'
                          : 'Arsipkan',
                    ),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(onPressed: _save, child: const Text('Simpan')),
                ),
              ],
            ),
            if (c != null && !unused && !archived)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Dipakai ${c['used']} transaksi/tagihan, jadi diarsipkan, bukan dihapus. '
                  'Kategori arsip tidak muncul di pilihan dan tebak otomatis.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
