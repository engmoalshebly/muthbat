class CurrencyInfo {
  final String code;
  final String name;
  final String symbol;
  final int decimalScale;
  final bool isActive;

  const CurrencyInfo({
    required this.code,
    required this.name,
    required this.symbol,
    this.decimalScale = 4,
    this.isActive = true,
  });

  factory CurrencyInfo.fromMap(Map<String, dynamic> map) {
    final code = (map['code'] as String).toUpperCase();
    final fallback = CurrencyCatalog.forCode(code);
    final rawName = map['name'] as String?;
    final rawSymbol = map['symbol'] as String?;

    return CurrencyInfo(
      code: code,
      name: CurrencyCatalog.isCorruptedLabel(rawName)
          ? fallback.name
          : (rawName ?? code),
      symbol: CurrencyCatalog.isCorruptedLabel(rawSymbol)
          ? fallback.symbol
          : (rawSymbol ?? code),
      decimalScale: (map['decimal_scale'] as num?)?.toInt() ?? 4,
      isActive: map['is_active'] is bool
          ? map['is_active'] as bool
          : (map['is_active'] as num?)?.toInt() != 0,
    );
  }

  Map<String, dynamic> toMap() => {
    'code': code,
    'name': name,
    'symbol': symbol,
    'decimal_scale': decimalScale,
    'is_active': isActive ? 1 : 0,
  };
}

class CurrencyCatalog {
  CurrencyCatalog._();

  static const defaults = <CurrencyInfo>[
    CurrencyInfo(code: 'YER', name: 'ريال يمني', symbol: 'ر.ي'),
    CurrencyInfo(code: 'SAR', name: 'ريال سعودي', symbol: 'ر.س'),
    CurrencyInfo(code: 'USD', name: 'دولار أمريكي', symbol: r'$'),
    CurrencyInfo(code: 'EUR', name: 'يورو', symbol: '€'),
    CurrencyInfo(code: 'AED', name: 'درهم إماراتي', symbol: 'د.إ'),
    CurrencyInfo(code: 'KWD', name: 'دينار كويتي', symbol: 'د.ك'),
    CurrencyInfo(code: 'QAR', name: 'ريال قطري', symbol: 'ر.ق'),
    CurrencyInfo(code: 'BHD', name: 'دينار بحريني', symbol: 'د.ب'),
    CurrencyInfo(code: 'OMR', name: 'ريال عماني', symbol: 'ر.ع'),
    CurrencyInfo(code: 'GBP', name: 'جنيه إسترليني', symbol: '£'),
    CurrencyInfo(code: 'JPY', name: 'ين ياباني', symbol: '¥'),
  ];

  static CurrencyInfo forCode(
    String code, [
    Iterable<CurrencyInfo> source = defaults,
  ]) {
    final upper = code.toUpperCase();
    final candidate = source.cast<CurrencyInfo?>().firstWhere(
      (currency) => currency?.code == upper,
      orElse: () => null,
    );
    if (candidate != null &&
        !isCorruptedLabel(candidate.name) &&
        !isCorruptedLabel(candidate.symbol)) {
      return candidate;
    }

    return defaults.cast<CurrencyInfo?>().firstWhere(
          (currency) => currency?.code == upper,
          orElse: () => null,
        ) ??
        CurrencyInfo(code: upper, name: upper, symbol: upper);
  }

  /// Protects the UI from legacy rows that were stored as mojibake or literal
  /// question marks before the official currency catalog was introduced.
  static bool isCorruptedLabel(String? value) {
    if (value == null || value.trim().isEmpty) return true;
    return value.contains('?') ||
        value.contains('\uFFFD') ||
        value.contains('Ø') ||
        value.contains('Ù') ||
        value.contains('Â') ||
        value.contains('Ã') ||
        value.contains('â');
  }
}
