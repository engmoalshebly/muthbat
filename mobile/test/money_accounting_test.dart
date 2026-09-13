import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/core/finance/currency_info.dart';
import 'package:muthbat/core/finance/money.dart';

void main() {
  test('official currencies enforce their own decimal scale', () {
    final scales = {
      for (final currency in CurrencyCatalog.defaults)
        currency.code: currency.decimalScale,
    };
    expect(scales['JPY'], 0);
    expect(scales['USD'], 2);
    expect(scales['KWD'], 3);
    expect(
      () => Money.fromCurrencyText('1.01', decimalScale: scales['JPY']!),
      throwsFormatException,
    );
    expect(
      Money.fromCurrencyText('1.234', decimalScale: scales['KWD']!).minorUnits,
      12340,
    );
  });

  test('five thousand mixed operations reconcile exactly per currency', () {
    final random = Random(20260913);
    final localBalances = <String, Money>{};
    final journalAr = <String, Money>{};
    final debits = <String, Money>{};
    final credits = <String, Money>{};

    for (var i = 0; i < 5000; i++) {
      final currency = CurrencyCatalog.defaults[i % 3];
      final quantum = Money.factor ~/ pow(10, currency.decimalScale).toInt();
      final amount = Money.fromMinorUnits(
        (random.nextInt(100000) + 1) * quantum,
      );
      final isDebit = i % 4 < 2; // debt/opening versus payment/discount
      final signed = isDebit
          ? amount
          : Money.fromMinorUnits(-amount.minorUnits);
      localBalances[currency.code] =
          (localBalances[currency.code] ?? const Money.fromMinorUnits(0)) +
          signed;
      journalAr[currency.code] =
          (journalAr[currency.code] ?? const Money.fromMinorUnits(0)) + signed;
      if (isDebit) {
        debits[currency.code] =
            (debits[currency.code] ?? const Money.fromMinorUnits(0)) + amount;
      } else {
        credits[currency.code] =
            (credits[currency.code] ?? const Money.fromMinorUnits(0)) + amount;
      }
    }

    for (final currency in localBalances.keys) {
      expect(
        localBalances[currency]!.minorUnits,
        journalAr[currency]!.minorUnits,
      );
      expect(
        localBalances[currency]!.minorUnits,
        debits[currency]!.minorUnits - credits[currency]!.minorUnits,
      );
    }
    expect(localBalances.keys, containsAll(['YER', 'SAR', 'USD']));
  });
}
