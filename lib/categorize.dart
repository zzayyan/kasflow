import 'dart:convert';

import 'db.dart';

/// Picks the category whose keyword appears in [text] as a whole word.
/// The longest matching keyword wins, so "grabfood" (Makan) beats "grab" (Transportasi).
/// [categories] are rows with `id`, `type` and `keywords` (a JSON array as text, as synced by PowerSync).
String? guessCategoryId(String text, String type, List<Map<String, dynamic>> categories) {
  final lower = text.toLowerCase();
  String? best;
  var bestLength = 0;
  for (final c in categories) {
    if (c['type'] != type) continue;
    for (final k in _keywords(c['keywords'])) {
      if (k.length > bestLength && RegExp('\\b${RegExp.escape(k.toLowerCase())}\\b').hasMatch(lower)) {
        best = c['id'] as String;
        bestLength = k.length;
      }
    }
  }
  return best;
}

/// Notes typed before that continue [typed], for the Catatan field: [notes] are past notes, most
/// used first. Notes starting with it come first, then notes with a later word starting with it
/// ("ayam" finds "Nasi Ayam", not "Biaya"); at most [limit], never the text already typed. Case is
/// ignored.
List<String> noteSuggestions(List<String> notes, String typed, {int limit = 5}) {
  final t = typed.trim().toLowerCase();
  if (t.isEmpty) return const [];
  final starts = <String>[], contains = <String>[];
  for (final n in notes) {
    final l = n.toLowerCase();
    if (l == t) continue;
    if (l.startsWith(t)) {
      starts.add(n);
    } else if (l.contains(' $t')) {
      contains.add(n);
    }
  }
  return [...starts, ...contains].take(limit).toList();
}

List<String> _keywords(Object? raw) =>
    raw is String && raw.isNotEmpty ? (jsonDecode(raw) as List).cast<String>() : <String>[];

/// The keyword to learn from a note the user typed: lowercase, amounts and digits removed,
/// at most 3 words. Null when nothing usable is left ("25rb", "", a long sentence).
String? keywordFromNote(String note) {
  final words = note
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty && !RegExp(r'\d').hasMatch(w) && w != 'rp')
      .toList();
  if (words.isEmpty || words.length > 3) return null;
  final keyword = words.join(' ');
  return keyword.length <= 30 && RegExp(r'[a-z]').hasMatch(keyword) ? keyword : null;
}

/// A keyword typed in the category form: lowercase, single spaces, at most 30 characters and at
/// least one letter ("7-Eleven" -> "7-eleven"). Null when unusable.
String? normalizeKeyword(String raw) {
  final k = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  return k.isEmpty || k.length > 30 || !RegExp(r'[a-z]').hasMatch(k) ? null : k;
}

/// One keyword, one category: gives [keywords] to [targetId] and removes them from every other
/// category in [current] (id -> keywords, same type). Returns only the lists that changed.
Map<String, List<String>> reassignKeywords(Map<String, List<String>> current, String targetId, List<String> keywords) {
  bool same(List<String> a, List<String> b) =>
      a.length == b.length && Iterable.generate(a.length).every((i) => a[i] == b[i]);
  return {
    for (final e in {...current, targetId: current[targetId] ?? const <String>[]}.entries)
      if (e.key == targetId ? keywords : e.value.where((k) => !keywords.contains(k)).toList() case final next
          when !same(next, e.value))
        e.key: next,
  };
}

/// Writes [keywords] to [categoryId] and takes them away from the other categories of its type.
/// Runs inside [tx], a PowerSync write transaction.
Future<void> _assignKeywords(
  dynamic tx,
  String categoryId,
  List<String> Function(List<String> current) keywords,
) async {
  final target = await tx.get('SELECT type FROM categories WHERE id = ?', [categoryId]);
  final rows = await tx.getAll('SELECT id, keywords FROM categories WHERE type = ?', [target['type']]);
  final current = {for (final r in rows) r['id'] as String: _keywords(r['keywords'])};
  final changed = reassignKeywords(current, categoryId, keywords(current[categoryId] ?? const []));
  for (final e in changed.entries) {
    await tx.execute('UPDATE categories SET keywords = ?, updated_at = ? WHERE id = ?', [
      jsonEncode(e.value),
      nowIso(),
      e.key,
    ]);
  }
}

/// Learning from corrections: the user picked [categoryId] for [note], so the note's keyword now
/// points there and is removed from other categories of the same type. Synced like any edit.
Future<void> learnKeyword(String note, String categoryId) async {
  final keyword = keywordFromNote(note);
  if (keyword == null) return;
  await db.writeTransaction(
    (tx) => _assignKeywords(tx, categoryId, (current) => current.contains(keyword) ? current : [...current, keyword]),
  );
}

/// Creates ([id] null) or edits a category and returns its id. The type of an existing category
/// never changes: its records would end up under a category of the other type.
Future<String> saveCategory({
  String? id,
  required String name,
  required String type,
  required String? needLevel,
  required List<String> keywords,
  String? icon, // a key of categoryIcons (lib/ui.dart); null = guessed from the name
}) {
  return db.writeTransaction((tx) async {
    final now = nowIso();
    final categoryId = id ?? (await tx.get('SELECT uuid() AS id'))['id'] as String;
    if (id == null) {
      await tx.execute(
        '''
        INSERT INTO categories (id, user_id, name, type, need_level, icon, keywords, archived, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, '[]', 0, ?, ?)''',
        [categoryId, currentUserId, name, type, needLevel, icon, now, now],
      );
    } else {
      await tx.execute('UPDATE categories SET name = ?, need_level = ?, icon = ?, updated_at = ? WHERE id = ?', [
        name,
        needLevel,
        icon,
        now,
        id,
      ]);
    }
    await _assignKeywords(tx, categoryId, (_) => keywords);
    return categoryId;
  });
}
