/// Customer contact contract. Keep aligned with _shared/customer-phone.ts.
String normalizeCustomerPhone(String input) {
  var value = input
      .trim()
      .replaceAllMapped(RegExp('[٠-٩۰-۹]'), (match) {
        final code = match[0]!.codeUnitAt(0);
        return (code - (code >= 0x6f0 ? 0x6f0 : 0x660)).toString();
      })
      .replaceAll(RegExp(r'[\s().\-]'), '');
  if (value.startsWith('00')) value = '+${value.substring(2)}';
  if (!value.startsWith('+')) {
    if (value.startsWith('0')) value = value.substring(1);
    value = value.startsWith('967') || value.length > 9
        ? '+$value'
        : '+967$value';
  }
  if (!RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(value)) {
    throw const FormatException('رقم الهاتف غير صالح');
  }
  return value;
}
