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

/// Learning from corrections: the user picked [categoryId] for [note], so the note's keyword now
/// points there and is removed from other categories of the same type. Synced like any edit.
Future<void> learnKeyword(String note, String categoryId) async {
  final keyword = keywordFromNote(note);
  if (keyword == null) return;
  await db.writeTransaction((tx) async {
    final target = await tx.get('SELECT type FROM categories WHERE id = ?', [categoryId]);
    final rows = await tx.getAll('SELECT id, keywords FROM categories WHERE type = ?', [target['type']]);
    for (final r in rows) {
      final current = _keywords(r['keywords']);
      final updated = r['id'] == categoryId
          ? (current.contains(keyword) ? current : [...current, keyword])
          : current.where((k) => k != keyword).toList();
      if (updated.length != current.length) {
        await tx.execute('UPDATE categories SET keywords = ?, updated_at = ? WHERE id = ?', [
          jsonEncode(updated),
          nowIso(),
          r['id'],
        ]);
      }
    }
  });
}
