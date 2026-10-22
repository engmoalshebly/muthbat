import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/core/telemetry/crash_reporting.dart';

void main() {
  test('disabled without a DSN', () => expect(CrashReporting.enabled, isFalse));

  test('scrub removes phone-like numbers', () {
    expect(
      CrashReporting.scrub('failed for +967 771 234 567 and 0771234567'),
      'failed for [number] and [number]',
    );
    expect(CrashReporting.scrub('code 42'), 'code 42');
  });
}
