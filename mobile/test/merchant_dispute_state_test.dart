import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/features/merchant/data/merchant_repository.dart';
import 'package:muthbat/features/merchant/data/models/dispute_model.dart';
import 'package:muthbat/features/merchant/data/models/dispute_message_model.dart';
import 'package:muthbat/features/merchant/presentation/controllers/merchant_controller.dart';
import 'package:muthbat/features/merchant/presentation/screens/dispute_detail_screen.dart';

const dispute = DisputeModel(
  id: 'dispute',
  entryId: 'entry',
  businessId: 'business',
  customerId: 'customer',
  reason: 'unknown_transaction',
  description: 'لم أقم بهذه العملية',
  entryAmount: 5000,
  currencyCode: 'SAR',
);

class DecisionRepository extends MerchantRepository {
  String? queueStatus;
  DisputeModel current = dispute;
  DecisionRepository(this.queueStatus) : super(requestSync: () {});
  @override
  Future<List<DisputeMessageModel>> getDisputeMessages(String id) async => [];
  @override
  Future<List<DisputeModel>> getCachedDisputes(String id) async => [current];
  @override
  Future<Map<String, dynamic>?> getDisputeResolutionQueue(String id) async =>
      queueStatus == null
      ? null
      : {
          'status': queueStatus,
          'payload_json': jsonEncode({'p_resolution': 'rejected'}),
          'last_error': 'server rejection',
        };
}

void main() {
  testWidgets(
    'merchant reply stays directly above keyboard without double inset',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            merchantRepositoryProvider.overrideWithValue(
              DecisionRepository(null),
            ),
          ],
          child: const MaterialApp(
            home: Directionality(
              textDirection: TextDirection.rtl,
              child: DisputeDetailScreen(dispute: dispute),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      final closedBottom = tester.getBottomLeft(field).dy;
      await tester.tap(field);
      await tester.enterText(field, 'رد التاجر محفوظ أثناء الكتابة');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      final keyboardTop = 844 - 300;
      expect(
        keyboardTop - tester.getBottomLeft(field).dy,
        inInclusiveRange(0, 24),
      );
      expect(find.text('رد التاجر محفوظ أثناء الكتابة'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(tester.getBottomLeft(field).dy, closeTo(closedBottom, 1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'pending decision is distinct from awaiting merchant and disables conflicting actions',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = DecisionRepository('pending');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [merchantRepositoryProvider.overrideWithValue(repo)],
          child: const MaterialApp(
            home: Directionality(
              textDirection: TextDirection.rtl,
              child: DisputeDetailScreen(dispute: dispute),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('رفض الاعتراض • محفوظ على الجهاز'), findsOneWidget);
      expect(find.text('قرار محفوظ'), findsOneWidget);
      expect(find.text('اتخاذ قرار'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('5,000 SAR'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'permanent rejection points to review and does not claim approval',
    (tester) async {
      final repo = DecisionRepository('dead_letter');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [merchantRepositoryProvider.overrideWithValue(repo)],
          child: const MaterialApp(home: DisputeDetailScreen(dispute: dispute)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('تعذر اعتماد القرار'), findsOneWidget);
      expect(find.text('مراجعة الإرسال'), findsOneWidget);
      expect(find.text('تحتاج مراجعة'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
