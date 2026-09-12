import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/core/security/app_lock_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('PIN is hashed, verified and removed when lock is disabled', () async {
    const storage = FlutterSecureStorage();
    final service = AppLockService(storage: storage);

    await service.setPin('123456');

    expect(await service.isEnabled, isTrue);
    expect(await service.isConfigured, isTrue);
    expect(await service.verifyPin('123456'), isTrue);
    expect(await storage.read(key: 'app_lock_pin_hash_v1'), isNot('123456'));

    await service.disable();
    expect(await service.isEnabled, isFalse);
    expect(await service.isConfigured, isFalse);
  });

  test('rejects malformed PINs and locks after repeated failures', () async {
    final service = AppLockService(storage: const FlutterSecureStorage());

    expect(() => service.setPin('12345'), throwsA(isA<FormatException>()));
    await service.setPin('654321');
    for (
      var attempt = 0;
      attempt < AppLockService.maxAttemptsBeforeLockout;
      attempt++
    ) {
      expect(await service.verifyPin('000000'), isFalse);
    }

    expect(await service.lockedOutUntil, isNotNull);
    expect(await service.verifyPin('654321'), isFalse);
  });

  test('accepts only the supported automatic lock timeouts', () async {
    final service = AppLockService(storage: const FlutterSecureStorage());

    await service.setAutoLockTimeout(const Duration(minutes: 1));
    expect(await service.autoLockTimeout, const Duration(minutes: 1));
    expect(
      () => service.setAutoLockTimeout(const Duration(seconds: 17)),
      throwsArgumentError,
    );
  });
}
