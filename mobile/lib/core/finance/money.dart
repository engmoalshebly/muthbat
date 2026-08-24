/// Fixed-point money helper. Monetary values cross the API as canonical
/// decimal strings and are represented internally as four-decimal minor units.
class Money {
  static const int scale = 4;
  static const int factor = 10000;

  final int minorUnits;
  const Money.fromMinorUnits(this.minorUnits);

  factory Money.fromText(String value) {
    final normalized = value.trim().replaceAll(',', '');
    if (!RegExp(r'^-?\d+(\.\d{1,4})?$').hasMatch(normalized)) {
      throw const FormatException('Invalid monetary amount');
    }
    final negative = normalized.startsWith('-');
    final unsigned = negative ? normalized.substring(1) : normalized;
    final parts = unsigned.split('.');
    final fraction = (parts.length == 2 ? parts[1] : '').padRight(scale, '0');
    final minor =
        int.parse(parts[0]) * factor +
        (fraction.isEmpty ? 0 : int.parse(fraction));
    return Money.fromMinorUnits(negative ? -minor : minor);
  }

  factory Money.fromNum(num value) => Money.fromText(value.toString());

  static Money? tryParse(String value) {
    try {
      return Money.fromText(value);
    } on FormatException {
      return null;
    }
  }

  String toDecimalString() {
    final absolute = minorUnits.abs();
    final whole = absolute ~/ factor;
    final fraction = (absolute % factor).toString().padLeft(scale, '0');
    return '${minorUnits < 0 ? '-' : ''}$whole.$fraction';
  }

  double toDouble() => minorUnits / factor;
}
