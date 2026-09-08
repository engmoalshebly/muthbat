import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/features/customer/data/customer_repository.dart';
import 'package:muthbat/features/customer/data/models/customer_summary_model.dart';

void main() {
  test(
    'invitation accepts limited pre-consent metadata without financial data',
    () {
      final invitation = CustomerLinkRequestModel.fromMap({
        'id': 'request-1',
        'business_name': 'بقالة الأمانة',
        'business_city': 'عدن',
      });
      expect(invitation.businessName, 'بقالة الأمانة');
      expect(invitation.businessCity, 'عدن');
      expect(invitation.localDisplayName, isEmpty);
      expect(invitation.status, 'pending');
    },
  );

  test(
    'timeout does not imply a financial operation failed or should be repeated',
    () {
      final message = CustomerRepository().friendlyError(
        TimeoutException('late'),
      );
      expect(message, contains('للتحقق من النتيجة'));
    },
  );
}
