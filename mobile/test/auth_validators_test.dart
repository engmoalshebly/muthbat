import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/features/auth/presentation/validators/auth_validators.dart';

void main() {
  group('AuthValidators', () {
    test('normalizes local and Arabic-Indic phone input', () {
      expect(
        AuthValidators.normalizePhone(raw: '٧٧١٢٣٤٥٦٧', dialCode: '+967'),
        '+967771234567',
      );
      expect(
        AuthValidators.normalizePhone(raw: '0771234567', dialCode: '+967'),
        '+967771234567',
      );
    });

    test('rejects malformed phone and password values', () {
      expect(
        AuthValidators.phoneError(raw: 'abc1234567', dialCode: '+967'),
        isNotNull,
      );
      expect(AuthValidators.passwordError('short'), isNotNull);
      expect(AuthValidators.passwordError('a' * 129), isNotNull);
      expect(AuthValidators.passwordError('valid password'), isNull);
    });

    test('accepts only six digit OTP values', () {
      expect(AuthValidators.otpError('١٢٣٤٥٦'), isNull);
      expect(AuthValidators.otpError('12345'), isNotNull);
      expect(AuthValidators.otpError('1234567'), isNotNull);
    });
  });
}
