import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/core/validation/customer_phone.dart';

void main() {
  final cases =
      jsonDecode(
            File('../test-fixtures/customer-phones.json').readAsStringSync(),
          )
          as List;
  for (final value in cases) {
    test('customer phone contract: ${value['input']}', () {
      if (value['expected'] == null) {
        expect(
          () => normalizeCustomerPhone(value['input']),
          throwsFormatException,
        );
      } else {
        expect(normalizeCustomerPhone(value['input']), value['expected']);
      }
    });
  }
}
