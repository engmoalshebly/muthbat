import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../lib/features/auth/presentation/customer_entry_mode.dart';

void main() {
  test('workspace preference is isolated per account', () async {
    SharedPreferences.setMockInitialValues({});
    await CustomerEntryMode.remember('first', true);
    expect(await CustomerEntryMode.selected('first'), isTrue);
    expect(await CustomerEntryMode.selected('second'), isFalse);
    await CustomerEntryMode.remember('first', false);
    expect(await CustomerEntryMode.selected('first'), isFalse);
  });
}
