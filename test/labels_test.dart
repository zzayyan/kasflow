import 'package:cashflow_app/labels_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('labelKey matches hashtags to label names', () {
    expect(labelKey('#x'.substring(1)), 'x');
    expect(labelKey('Liburan Bali'), labelKey('liburan-bali'));
    expect(labelKey('LiburanBali'), labelKey('liburan_bali'));
    expect(labelKey('kantor'), isNot(labelKey('kantor2')));
  });

  test('labelIdsOf reads the JSON column', () {
    expect(labelIdsOf('["a","b"]'), ['a', 'b']);
    expect(labelIdsOf(null), isEmpty);
    expect(labelIdsOf(''), isEmpty);
  });
}
