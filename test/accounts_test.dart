import 'package:cashflow_app/screens/accounts_tab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accountInitials: short names whole, capitals or first letters otherwise', () {
    expect(accountInitials('BCA'), 'BCA');
    expect(accountInitials('GoPay'), 'GP');
    expect(accountInitials('DANA'), 'DA');
    expect(accountInitials('Bank Jago'), 'BJ');
    expect(accountInitials('Mandiri'), 'MA');
    expect(accountInitials('ovo'), 'OVO');
    expect(accountInitials(' '), '?');
  });
}
