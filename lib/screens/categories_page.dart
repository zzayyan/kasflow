import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../categorize.dart';
import '../db.dart';
import '../theme.dart';
import '../ui.dart';

// A3: manage categories (name, wajib/butuh/ingin level, icon, keywords, archive), after the
// "Kelola kategori" and "Form kategori + ikon" artboards of the Cashflow UI/UX canvas.
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
  bool _showArchived = false;
  List<Map<String, dynamic>>? _rows;
  late final StreamSubscription<void> _sub;

  @override
  void initState() {
    super.initState();
    // `used` counts what points at the category: records and bills. Unused ones can be deleted;
    // used ones are archived instead, so history keeps its categories.
    _sub = db
        .watch('''
          SELECT c.*,
            (SELECT count(*) FROM records r WHERE r.category_id = c.id)
              + (SELECT count(*) FROM planned_payments p WHERE p.category_id = c.id) AS used
          FROM categories c
          ORDER BY c.name COLLATE NOCASE''')
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
    final rows = _rows ?? const [];
    int countOf(String type) => rows.where((r) => r['type'] == type && r['archived'] == 0).length;
    final ofType = rows.where((r) => r['type'] == _type).toList();
    final active = ofType.where((r) => r['archived'] == 0).toList();
    final archived = ofType.where((r) => r['archived'] != 0).toList();
    return Scaffold(
      appBar: pageAppBar(
        context,
        'Kategori',
        action: AddButton(tooltip: 'Tambah kategori', onPressed: () => showCategoryForm(context, type: _type)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 28),
        children: [
          PillSwitch(
            options: [('expense', 'Pengeluaran (${countOf('expense')})'), ('income', 'Pemasukan (${countOf('income')})')],
            value: _type,
            onChanged: (t) => setState(() => _type = t),
          ),
          const SizedBox(height: 16),
          if (_type == 'expense') ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  for (final level in const ['must', 'need', 'want'])
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Dot(c.needLevels[level]!),
                        const SizedBox(width: 6),
                        Text(needLevelLabels[level]!, style: AppText.caption),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (active.isNotEmpty) _CategoryList(active),
          const SizedBox(height: 16),
          Text(
            'Kata kunci bertambah sendiri saat kamu mengganti kategori hasil tebakan.',
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(color: c.inkMuted, height: 1.4),
          ),
          if (archived.isNotEmpty) ...[
            const SizedBox(height: 8),
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
            if (_showArchived) _CategoryList(archived),
          ],
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.color, {this.size = 10});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) =>
      Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

class _CategoryList extends StatelessWidget {
  const _CategoryList(this.categories);

  final List<Map<String, dynamic>> categories;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            for (final (i, cat) in categories.indexed) ...[
              if (i > 0) const Divider(indent: 16, endIndent: 16),
              _CategoryRow(cat),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow(this.cat);

  final Map<String, dynamic> cat;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final type = cat['type'] as String;
    final keywords = _keywordsOf(cat).length;
    final archived = cat['archived'] != 0;
    final level = cat['need_level'] as String?;
    final (dot, levelText) = type == 'income'
        ? (c.income, 'Pemasukan')
        : (c.needLevels[level]!, level == null ? 'Tanpa level' : needLevelLabels[level]!);
    return InkWell(
      onTap: () => showCategoryForm(context, type: type, category: cat),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 62),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: archived ? c.surfaceMuted : c.primarySoft, shape: BoxShape.circle),
                child: Icon(
                  categoryIcon(cat['name'] as String?, type, cat['icon'] as String?),
                  size: 20,
                  color: archived ? c.inkMuted : c.primary,
                ),
              ),
              const SizedBox(width: AppSpace.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cat['name'] as String,
                      style: AppText.bodyStrong.copyWith(color: archived ? c.inkMuted : null),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      keywords == 0 ? 'Belum ada kata kunci' : '$keywords kata kunci',
                      style: AppText.caption.copyWith(color: c.inkMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(10)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Dot(dot, size: 8),
                    const SizedBox(width: 6),
                    Text(levelText, style: AppText.caption),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showCategoryForm(BuildContext context, {required String type, Map<String, dynamic>? category}) async {
  final siblings = await db.getAll('SELECT id, name, keywords FROM categories WHERE type = ?', [type]);
  if (!context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => CategoryForm(type: type, category: category, siblings: siblings)),
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
  late String _level = (widget.category?['need_level'] as String?) ?? '';
  late String? _icon = categoryIconKey(widget.category?['name'] as String?, widget.category?['icon'] as String?);
  late final List<String> _keywords = widget.category == null ? [] : _keywordsOf(widget.category!);
  String? _notice;

  String? get _id => widget.category?['id'] as String?;

  // Who owns each keyword now, among the other categories of this type.
  late final Map<String, String> _owners = {
    for (final s in widget.siblings)
      if (s['id'] != _id)
        for (final k in _keywordsOf(s)) k: s['name'] as String,
  };

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _addKeyword() async {
    final input = TextEditingController();
    final typed = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kata kunci baru'),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'contoh: mixue, indomaret'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(context, input.text), child: const Text('Tambah')),
        ],
      ),
    );
    final k = normalizeKeyword(typed ?? '');
    if (k == null || _keywords.contains(k)) return;
    setState(() {
      _keywords.add(k);
      final owner = _owners[k];
      _notice = owner == null ? null : '"$k" akan dipindah dari $owner';
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _notice = 'Isi nama kategori.');
    final duplicate = widget.siblings.any(
      (s) => s['id'] != _id && (s['name'] as String).toLowerCase() == name.toLowerCase(),
    );
    if (duplicate) return setState(() => _notice = 'Kategori "$name" sudah ada.');
    await saveCategory(
      id: _id,
      name: name,
      type: widget.type,
      needLevel: widget.type == 'expense' && _level.isNotEmpty ? _level : null,
      icon: _icon,
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

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final cat = widget.category;
    final unused = cat != null && (cat['used'] as int) == 0;
    final archived = cat != null && cat['archived'] != 0;
    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(title, style: AppText.label.copyWith(color: c.inkMuted)),
          ),
          ...children,
        ],
      ),
    );
    return Scaffold(
      appBar: pageAppBar(context, cat == null ? 'Kategori baru' : 'Ubah kategori'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 20),
        children: [
          Row(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(color: c.hero, shape: BoxShape.circle),
                child: Icon(categoryIcon(_name.text, widget.type, _icon), size: 28, color: c.onHero),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: TextField(
                  controller: _name,
                  autofocus: cat == null,
                  onChanged: (_) => setState(() {}), // the preview icon follows the name until one is picked
                  style: AppText.body.copyWith(fontSize: 16, fontWeight: FontWeight.w500),
                  decoration: const InputDecoration(labelText: 'Nama'),
                ),
              ),
            ],
          ),
          if (widget.type == 'expense')
            section('Seberapa penting?', [
              Row(
                children: [
                  for (final (i, level) in const ['must', 'need', 'want', ''].indexed) ...[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(
                      child: Semantics(
                        selected: _level == level,
                        child: OutlinedButton(
                          onPressed: () => setState(() => _level = level),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.input)),
                            backgroundColor: _level == level ? c.surface : c.surfaceMuted,
                            side: BorderSide(color: _level == level ? c.primary : Colors.transparent, width: 2),
                            foregroundColor: c.ink,
                            textStyle: AppText.label.copyWith(fontSize: 14, fontWeight: FontWeight.w500),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _Dot(c.needLevels[level.isEmpty ? null : level]!),
                              const SizedBox(width: 6),
                              Text(level.isEmpty ? 'Tanpa' : needLevelLabels[level]!),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 8),
                child: Text(
                  'Dipakai untuk ringkasan Wajib, Butuh, Ingin di Laporan.',
                  style: AppText.caption.copyWith(color: c.inkMuted),
                ),
              ),
            ]),
          section('Ikon', [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
              child: GridView.count(
                crossAxisCount: 6,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final MapEntry(key: key, value: (icon, label)) in categoryIcons.entries)
                    IconButton(
                      tooltip: label,
                      isSelected: _icon == key,
                      onPressed: () => setState(() => _icon = key),
                      style: IconButton.styleFrom(
                        backgroundColor: _icon == key ? c.primary : Colors.transparent,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.input)),
                      ),
                      icon: Icon(icon, size: 22, color: _icon == key ? c.onPrimary : c.ink),
                    ),
                ],
              ),
            ),
          ]),
          section('Kata kunci untuk tebakan otomatis', [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final k in _keywords)
                  InputChip(
                    label: Text(k),
                    onDeleted: () => setState(() => _keywords.remove(k)),
                    deleteButtonTooltipMessage: 'Hapus $k',
                  ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: const Text('Tambah'),
                  backgroundColor: c.bg,
                  side: BorderSide(color: c.outline),
                  onPressed: _addKeyword,
                ),
              ],
            ),
          ]),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_notice!, style: AppText.label.copyWith(color: c.inkMuted)),
            ),
          if (cat != null && !unused && !archived)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Dipakai ${cat['used']} transaksi/tagihan, jadi diarsipkan, bukan dihapus. '
                'Kategori arsip tidak muncul di pilihan dan tebak otomatis.',
                style: AppText.caption.copyWith(color: c.inkMuted, height: 1.4),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(AppSpace.page, 12, AppSpace.page, 12 + MediaQuery.viewInsetsOf(context).bottom),
          child: Row(
            children: [
              if (cat != null) ...[
                OutlinedButton(
                  onPressed: _archiveOrDelete,
                  style: OutlinedButton.styleFrom(minimumSize: const Size(64, 56)),
                  child: Text(
                    unused
                        ? 'Hapus'
                        : archived
                        ? 'Pulihkan'
                        : 'Arsipkan',
                  ),
                ),
                const SizedBox(width: 10),
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
        ),
      ),
    );
  }
}
