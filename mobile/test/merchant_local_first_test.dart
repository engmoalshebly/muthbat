import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/features/merchant/data/merchant_repository.dart';
import 'package:muthbat/features/merchant/data/merchant_api_exception.dart';
import 'package:muthbat/features/merchant/data/local_statement_pdf.dart';
import 'package:muthbat/features/merchant/presentation/controllers/merchant_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = AppDatabase.instance;
  const owner = 'e1990000-0000-0000-0000-000000000001';
  var syncRequests = 0;
  late MerchantRepository repository;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
    final folder = await Directory.systemTemp.createTemp(
      'merchant-local-first-',
    );
    await databaseFactoryFfi.setDatabasesPath(folder.path);
    await store.bindAccount(owner);
    repository = MerchantRepository(requestSync: () => syncRequests++);
    await store.saveBusiness({
      'id': 'business',
      'owner_user_id': owner,
      'name': 'متجري',
      'is_active': 1,
      'currency_code': 'YER',
    });
    await store.upsertBusinessCustomer({
      'id': 'customer',
      'business_id': 'business',
      'local_display_name': 'زبوني',
      'sync_status': 'synced',
    });
    await store.saveLedgerEntryOptimistic(
      entry: {
        'id': 'entry',
        'business_id': 'business',
        'business_customer_id': 'customer',
        'entry_type': 'debt',
        'direction': 'debit',
        'amount': 100,
        'currency_code': 'YER',
        'description': 'دين',
        'occurred_at': '2026-10-22T00:00:00Z',
        'created_at': '2026-10-22T00:00:00Z',
        'client_request_id': 'seed-entry',
        'sync_status': 'synced',
      },
      commandType: 'create_ledger_entry',
      payload: {},
    );
    await store.upsertLocalDispute({
      'id': 'dispute',
      'entry_id': 'entry',
      'business_id': 'business',
      'customer_id': 'customer',
      'reason': 'wrong_amount',
      'description': 'المبلغ مختلف',
      'status': 'awaiting_merchant',
      'created_at': '2026-10-22T00:00:00Z',
    });
    await store.saveDisputeMessage({
      'id': 'message',
      'dispute_id': 'dispute',
      'sender_user_id': owner,
      'message': 'رسالة محفوظة',
      'created_at': '2026-10-22T00:00:00Z',
      'sync_status': 'synced',
    });
  });
  tearDownAll(() => store.lockAccount());
  test(
    'logo is persisted offline, preview survives reopen, and duplicate pending changes are blocked',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawColor(const ui.Color(0xff008877), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(32, 32);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = data!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      await repository.updateBusinessLogo(
        businessId: 'business',
        bytes: bytes,
        extension: 'wrong-extension',
      );
      final queued = (await store.getPendingMutations()).singleWhere(
        (q) => q['command_type'] == 'upload_business_logo',
      );
      final payload = jsonDecode(queued['payload_json'] as String) as Map;
      expect(payload['extension'], 'png');
      await expectLater(
        repository.updateBusinessLogo(
          businessId: 'business',
          bytes: bytes,
          extension: 'png',
        ),
        throwsA(
          isA<MerchantApiException>().having(
            (e) => e.code,
            'code',
            'logo_change_pending',
          ),
        ),
      );
      await expectLater(
        repository.updateBusinessLogo(
          businessId: 'someone-else',
          bytes: bytes,
          extension: 'png',
        ),
        throwsA(
          isA<MerchantApiException>().having((e) => e.code, 'code', '42501'),
        ),
      );
      await store.lockAccount();
      await store.bindAccount(owner);
      final controller = MerchantController(
        repository,
        activeBusinessId: 'business',
        requestSync: () {},
      );
      addTearDown(controller.dispose);
      await controller.loadDashboard();
      expect(controller.state.businessLogoPreview, isNotEmpty);
      expect(controller.state.businessLogoSyncStatus, 'pending');
    },
  );
  test(
    'statements and multi currency PDFs are ready without a cloud client',
    () async {
      final statement = (await repository.generateAllCurrenciesStatement(
        businessCustomerId: 'customer',
        periodFrom: '2026-10-01T00:00:00Z',
        periodTo: '2026-11-01T00:00:00Z',
        currencyCodes: ['YER', 'SAR'],
      ))!;
      expect(statement.combinedStatements, hasLength(2));
      expect(statement.combinedStatements.first.closingBalance, 100);
      expect(statement.combinedStatements.first.localEntries, hasLength(1));
      expect(statement.combinedStatements.last.closingBalance, 0);
      expect(statement.combinedStatements.last.localEntries, isEmpty);
      final bytes = await localStatementPdf(statement, 'زبوني');
      expect(utf8.decode(bytes.take(4).toList()), '%PDF');
      final queued = (await store.getPendingMutations()).where(
        (q) => q['command_type'] == 'generate_statement',
      );
      expect(queued, hasLength(2));
    },
  );
  test(
    'dashboard and pull-to-refresh finish locally while network work stays pending; warm refresh never hides data',
    () async {
      final cloudWork = Completer<void>();
      final controller = MerchantController(
        repository,
        activeBusinessId: 'business',
        requestSync: () {
          syncRequests++;
          unawaited(cloudWork.future);
        },
      );
      await controller.loadDashboard();
      expect(controller.state.businessId, 'business');
      expect(controller.state.businessName, 'متجري');
      final loading = <bool>[];
      final remove = controller.addListener(
        (state) => loading.add(state.isLoading),
        fireImmediately: false,
      );
      final refreshed = await controller.syncNow().timeout(
        const Duration(seconds: 2),
      );
      expect(refreshed, isTrue);
      expect(cloudWork.isCompleted, isFalse);
      expect(loading, everyElement(isFalse));
      expect(controller.state.totalReceivables, 100);
      cloudWork.complete();
      remove();
      controller.dispose();
    },
  );
  test(
    'missing local business returns immediately without initializing or contacting Supabase',
    () async {
      final controller = MerchantController(
        repository,
        activeBusinessId: 'not-downloaded',
        requestSync: () {},
      );
      await controller.loadDashboard().timeout(const Duration(seconds: 2));
      expect(controller.state.isLoading, isFalse);
      expect(controller.state.businessId, isEmpty);
      controller.dispose();
    },
  );
  test(
    'disputes and messages read the device; decision queues once and keeps finances unconfirmed until server acceptance',
    () async {
      final disputes = await repository.getDisputes('business');
      expect(disputes.single.customerDisplayName, 'زبوني');
      expect(disputes.single.entryAmount, 100);
      expect(
        (await repository.getDisputeMessages('dispute')).single.message,
        'رسالة محفوظة',
      );
      final before = await store.getCustomerCurrencyBalances('customer');
      await repository.resolveDispute(
        disputeId: 'dispute',
        resolution: 'partially_accepted',
        note: 'تصحيح',
        correctedAmount: 80,
      );
      expect(await repository.hasPendingDisputeResolution('dispute'), isTrue);
      final queuedDecision = await repository.getDisputeResolutionQueue(
        'dispute',
      );
      expect(queuedDecision?['status'], 'pending');
      expect(
        (jsonDecode(queuedDecision!['payload_json'] as String)
            as Map)['p_resolution'],
        'partially_accepted',
      );
      final queue = (await store.getPendingMutations())
          .where((q) => q['command_type'] == 'resolve_dispute')
          .toList();
      expect(queue, hasLength(1));
      final payload = jsonDecode(queue.single['payload_json'] as String) as Map;
      expect(payload['p_client_request_id'], queue.single['client_request_id']);
      expect(payload['p_corrected_amount'], 80);
      expect(await store.getCustomerCurrencyBalances('customer'), before);
      await expectLater(
        repository.addDisputeMessage('dispute', 'رد بعد القرار'),
        throwsStateError,
      );
      expect(
        (await repository.getDisputes('business')).single.status,
        'awaiting_merchant',
      );
      await expectLater(
        repository.resolveDispute(
          disputeId: 'dispute',
          resolution: 'rejected',
          note: 'قرار آخر',
        ),
        throwsStateError,
      );
      expect(syncRequests, greaterThan(0));
      await store.lockAccount();
      await store.bindAccount(owner);
      expect(await repository.hasPendingDisputeResolution('dispute'), isTrue);
    },
  );
}
