import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/features/customer/data/customer_repository.dart';
import 'package:muthbat/features/customer/data/models/customer_summary_model.dart';
import 'package:muthbat/features/customer/presentation/controllers/customer_controller.dart';

class FakeCustomerRepository extends CustomerRepository {
  static const owner = 'd1940000-0000-0000-0000-000000000001';
  @override
  String? get userId => owner;
  Object? linkFailure;
  int linkCalls = 0, reads = 0;
  String identity = 'old-identity';
  String? fetchedIdentity;
  @override
  Future<CustomerReadSnapshot> fetchHomeSnapshot() async {
    final id = await resolveCustomerId();
    return CustomerReadSnapshot(
      customerId: id,
      updatedAt: '2026-10-19T00:00:00Z',
      summaries: await fetchBusinessSummaries(id!),
      requests: [],
      entries: [],
    );
  }

  double balance = 10;
  Completer<void>? waitForLink;
  @override
  Future<void> refreshPhoneLinks() async {
    linkCalls++;
    await waitForLink?.future;
    if (linkFailure != null) throw linkFailure!;
    identity = 'claimed-identity';
  }

  @override
  Future<List<Map<String, dynamic>>> pendingActions() async => [];
  @override
  Future<void> flushOutbox() async {}
  @override
  Future<String?> resolveCustomerId() async => identity;
  @override
  Future<List<CustomerBusinessSummary>> fetchBusinessSummaries(
    String customerId,
  ) async {
    reads++;
    fetchedIdentity = customerId;
    return [
      CustomerBusinessSummary.fromMap({
        'business_customer_id': 'bc',
        'business_id': 'shop',
        'business_name': 'بقالة الاختبار',
        'business_type': 'retail',
        'currency_code': 'YER',
        'current_balance': balance,
        'entry_count': 1,
      }),
    ];
  }

  @override
  Future<List<CustomerLinkRequestModel>> fetchPendingLinkRequests(
    String customerId,
  ) async => [];
  @override
  Future<List<CustomerPendingEntry>> fetchPendingEntries(
    String customerId,
  ) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeCustomerRepository repo;
  late CustomerController controller;
  late DateTime now;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp(
      'customer-link-refresh-',
    );
    await databaseFactoryFfi.setDatabasesPath(directory.path);
    await AppDatabase.instance.bindAccount(FakeCustomerRepository.owner);
  });
  tearDownAll(() => AppDatabase.instance.lockAccount());
  setUp(() {
    repo = FakeCustomerRepository();
    now = DateTime.utc(2026, 10, 20);
    controller = CustomerController(repo, now: () => now);
  });
  tearDown(() => controller.dispose());

  test(
    'transient phone claim failure stays visible without hiding linked shops and retries on normal load',
    () async {
      repo.linkFailure = Exception('phone service unavailable');
      await controller.load();
      expect(controller.state.phoneLinkError, contains('unavailable'));
      expect(controller.state.summaries.length, 1);
      expect(controller.state.errorMessage, isNull);
      expect(controller.state.requiresPhoneVerification, isFalse);
      repo.linkFailure = null;
      await controller.load();
      expect(repo.linkCalls, 2);
      expect(repo.fetchedIdentity, 'claimed-identity');
      expect(controller.state.phoneLinkError, isNull);
    },
  );
  test(
    'a bypassed account has an explicit verification state while existing shops remain readable',
    () async {
      repo.linkFailure = const CustomerPhoneVerificationRequired();
      await controller.load();
      expect(controller.state.requiresPhoneVerification, isTrue);
      expect(controller.state.summaries.length, 1);
      repo.linkFailure = null;
      await controller.load();
      expect(controller.state.requiresPhoneVerification, isFalse);
    },
  );
  test(
    'idle refresh fetches new merchant debt even with an empty customer outbox',
    () async {
      await controller.load();
      final initialReads = repo.reads;
      repo.balance = 90;
      now = now.add(const Duration(seconds: 46));
      repo.waitForLink = Completer<void>();
      controller.refreshIfIdle();
      // Existing data stays visible while an idle refresh runs in the background.
      expect(controller.state.isLoading, isFalse);
      controller.refreshIfIdle();
      repo.waitForLink!.complete();
      for (var i = 0; i < 100 && repo.reads < initialReads + 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(repo.reads, initialReads + 2);
      expect(repo.linkCalls, 2);
      expect(controller.state.summaries.single.currentBalance, 90);
    },
  );
  test('first server data is visible while phone linking is stalled', () async {
    repo.waitForLink = Completer<void>();
    final loading = controller.load();
    for (var i = 0; i < 100 && controller.state.updatedAt == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(repo.waitForLink!.isCompleted, isFalse);
    expect(controller.state.isLoading, isFalse);
    expect(controller.state.customerId, 'old-identity');
    expect(controller.state.summaries.single.currentBalance, 10);
    repo.waitForLink!.complete();
    await loading;
    expect(controller.state.customerId, 'claimed-identity');
  });
}
