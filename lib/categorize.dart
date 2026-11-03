import 'dart:convert';

/// Picks the category whose keyword appears in [text] as a whole word.
/// The longest matching keyword wins, so "grabfood" (Makan) beats "grab" (Transportasi).
/// [categories] are rows with `id`, `type` and `keywords` (a JSON array as text, as synced by PowerSync).
String? guessCategoryId(String text, String type, List<Map<String, dynamic>> categories) {
  final lower = text.toLowerCase();
  String? best;
  var bestLength = 0;
  for (final c in categories) {
    if (c['type'] != type) continue;
    final raw = c['keywords'];
    final keywords = raw is String && raw.isNotEmpty ? (jsonDecode(raw) as List).cast<String>() : const <String>[];
    for (final k in keywords) {
      if (k.length > bestLength && RegExp('\\b${RegExp.escape(k.toLowerCase())}\\b').hasMatch(lower)) {
        best = c['id'] as String;
        bestLength = k.length;
      }
    }
  }
  return best;
}
