/// Shared validation and phone normalization for all authentication screens.
class AuthValidators {
  AuthValidators._();

  static String normalizeDigits(String value) {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      if (rune >= 0x0660 && rune <= 0x0669) {
        buffer.writeCharCode(0x30 + rune - 0x0660);
      } else if (rune >= 0x06F0 && rune <= 0x06F9) {
        buffer.writeCharCode(0x30 + rune - 0x06F0);
      } else if (rune >= 0x30 && rune <= 0x39) {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  static String normalizePhone({
    required String raw,
    required String dialCode,
  }) {
    var digits = normalizeDigits(raw);
    final countryDigits = normalizeDigits(dialCode);

    if (raw.trim().startsWith('00')) {
      digits = digits.length > 2 ? digits.substring(2) : '';
    }

    if (digits.startsWith(countryDigits) &&
        digits.length > countryDigits.length + 6) {
      return '+$digits';
    }

    if (digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    return '+$countryDigits$digits';
  }

  static String normalizeE164(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || RegExp(r'[^0-9٠-٩۰-۹\s().+\-]').hasMatch(trimmed)) {
      throw const FormatException('Phone contains invalid characters.');
    }
    var digits = normalizeDigits(trimmed);
    if (trimmed.startsWith('00')) {
      digits = digits.length > 2 ? digits.substring(2) : '';
    }
    if (digits.length < 8 || digits.length > 15) {
      throw const FormatException('Phone must contain 8 to 15 digits.');
    }
    return '+$digits';
  }

  static String? phoneError({required String raw, required String dialCode}) {
    final value = raw.trim();
    if (value.isEmpty) return 'يرجى إدخال رقم الهاتف';
    if (RegExp(r'[^0-9٠-٩۰-۹\s().+\-]').hasMatch(value)) {
      return 'رقم الهاتف يحتوي على أحرف أو رموز غير صحيحة';
    }

    final fullPhone = normalizePhone(raw: value, dialCode: dialCode);
    final digits = normalizeDigits(fullPhone);
    if (digits.length < 8 || digits.length > 15) {
      return 'يرجى إدخال رقم هاتف صحيح ومكتمل';
    }
    return null;
  }

  static String? nameError(String value) {
    final name = value.trim();
    if (name.isEmpty) return 'يرجى إدخال الاسم';
    if (name.length < 2) return 'الاسم قصير جدًا';
    if (name.length > 120) return 'الاسم طويل جدًا';
    if (RegExp(r'[\u0000-\u001F]').hasMatch(name)) {
      return 'الاسم يحتوي على محارف غير صالحة';
    }
    return null;
  }

  static String? passwordError(String value) {
    if (value.isEmpty) return 'يرجى إدخال كلمة السر';
    if (value.length < 8) return 'كلمة السر يجب ألا تقل عن 8 خانات';
    if (value.length > 128) return 'كلمة السر يجب ألا تتجاوز 128 خانة';
    return null;
  }

  static String normalizeOtp(String value) => normalizeDigits(value);

  static String? otpError(String value) {
    final code = normalizeOtp(value.trim());
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      return 'رمز التحقق يجب أن يتكون من 6 أرقام';
    }
    return null;
  }
}
