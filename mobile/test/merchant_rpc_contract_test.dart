import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/features/merchant/data/rpc_contract.dart';

void main() {
  group('Merchant RPC contract', () {
    test('ledger payload preserves the server contract and currency', () {
      final payload = RpcContract.createLedgerEntryPayload(
        businessCustomerId: 'customer-id',
        entryType: 'debt',
        amount: 1250.5,
        description: 'بضاعة أسبوعية',
        category: 'goods',
        paymentMethod: 'cash',
        occurredAt: '2026-09-01T12:00:00.000Z',
        clientRequestId: 'request-id',
        currencyCode: 'yer',
      );

      expect(payload['p_business_customer_id'], 'customer-id');
      expect(payload['p_amount'], '1250.5000');
      expect(payload['p_currency_code'], 'YER');
      expect(
        payload.keys,
        containsAll(<String>[
          'p_category',
          'p_payment_method',
          'p_client_request_id',
        ]),
      );
    });

    test('discount and reversal use their exact parameter names', () {
      final discount = RpcContract.applyCustomerDiscountPayload(
        businessCustomerId: 'customer-id',
        amount: 10,
        description: 'خصم',
        clientRequestId: 'request-id',
        currencyCode: 'sar',
      );
      final reversal = RpcContract.reverseLedgerEntryPayload(
        entryId: 'entry-id',
        reason: 'تصحيح',
        clientRequestId: 'request-id',
      );

      expect(discount['p_currency_code'], 'SAR');
      expect(reversal['p_entry_id'], 'entry-id');
      expect(reversal, isNot(contains('p_original_entry_id')));
    });

    test('employee invites use the phone-directory edge function', () {
      expect(RpcContract.edgeMemberInvite, 'member-invite');
    });
  });

  test('offline business reconciliation rewrites every nested reference', () {
    final rewritten =
        replaceReconciledIdDeep(
              {
                'businessId': 'biz-local',
                'nested': [
                  {'business_id': 'biz-local'},
                  'unchanged',
                ],
              },
              'biz-local',
              'b0d3d7f2-84c7-4bda-9c3f-0b66f5b568a1',
            )
            as Map;

    expect(rewritten['businessId'], 'b0d3d7f2-84c7-4bda-9c3f-0b66f5b568a1');
    expect(
      (rewritten['nested'] as List)[0]['business_id'],
      'b0d3d7f2-84c7-4bda-9c3f-0b66f5b568a1',
    );
  });
}
