import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:muthbat/features/customer/presentation/screens/customer_entry_details_screen.dart';
import 'package:muthbat/features/customer/data/customer_repository.dart';
import 'package:muthbat/features/customer/presentation/controllers/customer_controller.dart';

class DisputeTestRepository extends CustomerRepository {
  final requests = <Map<String, dynamic>>[];
  @override
  String? get userId => 'customer-owner';
  @override
  Future<List<Map<String, dynamic>>> pendingActions() async => [];
  @override
  Future<void> openDispute({
    required String entryId,
    required String reason,
    required String description,
  }) async {
    requests.add({
      'entry_id': entryId,
      'reason': reason,
      'description': description,
    });
  }
}

void main() {
  testWidgets('customer receipt displays status without merchant controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: CustomerEntryDetailsScreen(
            businessName: 'بقالة الاختبار',
            entry: {
              'id': 'receipt-1',
              'entry_type': 'payment',
              'amount': 25,
              'currency_code': 'YER',
              'description': 'سداد حساب',
              'occurred_at': '2026-09-11T10:00:00Z',
              'confirmation_status': 'pending',
              'dispute_status': 'open',
            },
          ),
        ),
      ),
    );
    expect(find.text('بقالة الاختبار'), findsOneWidget);
    expect(find.text('25 YER'), findsOneWidget);
    expect(find.text('سداد حساب'), findsOneWidget);
    expect(find.text('تعديل'), findsNothing);
    expect(find.text('حذف'), findsNothing);
    expect(find.text('مسجلة في الحساب'), findsOneWidget);
    expect(find.text('بانتظار التأكيد'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'previously confirmed receipt can queue an objection without an acceptance step',
    (tester) async {
      final repository = DisputeTestRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [customerRepositoryProvider.overrideWithValue(repository)],
          child: const MaterialApp(
            home: CustomerEntryDetailsScreen(
              businessName: 'متجري',
              entry: {
                'id': 'confirmed-entry',
                'entry_type': 'debt',
                'amount': 100,
                'currency_code': 'YER',
                'description': 'دين مسجل',
                'occurred_at': '2026-10-21T10:00:00Z',
                'confirmation_status': 'confirmed',
                'dispute_status': 'none',
                'is_reversed': false,
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('تأكيد'), findsNothing);
      expect(find.text('قبول'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('لدي مشكلة'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('لدي مشكلة'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('التالي'));
      await tester.pumpAndSettle();
      expect(repository.requests, isEmpty);
      await tester.tap(find.text('إرسال للتاجر'));
      await tester.pumpAndSettle();
      expect(find.text('اكتب توضيحًا قصيرًا للتاجر'), findsOneWidget);
      expect(repository.requests, isEmpty);
      await tester.enterText(find.byType(TextFormField), 'المبلغ الصحيح أقل');
      await tester.tap(find.text('رجوع'));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      expect(repository.requests, isEmpty);
      await tester.tap(find.text('التالي'));
      await tester.pumpAndSettle();
      expect(find.text('المبلغ الصحيح أقل'), findsOneWidget);
      await tester.tap(find.text('إرسال للتاجر'));
      await tester.pumpAndSettle();
      expect(repository.requests.single, {
        'entry_id': 'confirmed-entry',
        'reason': 'wrong_amount',
        'description': 'المبلغ الصحيح أقل',
      });
      expect(find.text('متابعة طلبك'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reversed entries cannot open another objection', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: CustomerEntryDetailsScreen(
            businessName: 'متجري',
            entry: {
              'id': 'reversed',
              'entry_type': 'debt',
              'amount': 10,
              'currency_code': 'YER',
              'is_reversed': true,
              'dispute_status': 'resolved',
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('لدي مشكلة'), findsNothing);
  });
}
