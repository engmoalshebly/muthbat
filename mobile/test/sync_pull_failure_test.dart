import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/core/sync/sync_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = 'f1900000-0000-0000-0000-000000000001';
  const business = 'f1900000-0000-0000-0000-000000000002';
  late SupabaseClient client;
  late SyncEngine engine;
  String? failingTable;
  var now = DateTime.utc(2026, 10, 19, 10);
  final events = <SyncProgress>[];
  final requests = <Uri>[];
  bool largeCurrencyPage = false;
  bool issueExpiredToken = false;
  int tokenRequests = 0;
  bool contactCustomer = false;
  bool archivedCustomer = false;
  Map<String, dynamic>? sentDebt;
  Map<String, dynamic>? snapshotParams;
  List<Map<String, dynamic>> snapshotItems = [];
  bool largeSnapshot = false, failSnapshotTail = false;
  final profileRequests = <Map<String, dynamic>>[];
  bool withDispute = false;
  Map<String, dynamic>? resolutionRequest;
  Map<String, dynamic>? profileUpdate;
  Map<String, dynamic>? sentMessage;
  var contractReady = true;
  var profileVisible = true;
  var resolutionResultMissing = false;
  Completer<void>? pullEntered;
  Completer<void>? releasePull;
  Completer<void>? resolutionSent;
  Completer<void>? disputeGate;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
    final folder = await Directory.systemTemp.createTemp('sync-pull-failure-');
    await databaseFactoryFfi.setDatabasesPath(folder.path);
    await AppDatabase.instance.bindAccount(owner);
  });
  tearDownAll(() async => AppDatabase.instance.lockAccount());

  setUp(() async {
    failingTable = null;
    events.clear();
    requests.clear();
    largeCurrencyPage = false;
    issueExpiredToken = false;
    tokenRequests = 0;
    contactCustomer = false;
    archivedCustomer = false;
    sentDebt = null;
    largeSnapshot = false;
    failSnapshotTail = false;
    profileRequests.clear();
    withDispute = false;
    resolutionRequest = null;
    profileUpdate = null;
    sentMessage = null;
    contractReady = true;
    profileVisible = true;
    resolutionResultMissing = false;
    pullEntered = null;
    releasePull = null;
    resolutionSent = null;
    disputeGate = null;
    now = DateTime.utc(2026, 10, 19, 10);
    client = SupabaseClient(
      'https://example.test',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        http.Response respond(Object? data, [int status = 200]) =>
            http.Response(
              jsonEncode(data),
              status,
              headers: {'content-type': 'application/json'},
              request: request,
            );
        final table = request.url.path.split('/').last;
        if (table == 'client_sync_contract') {
          return respond({
            'version': contractReady ? '20261022-profile-disputes-v1' : 'old',
          });
        }
        if (table == 'add_dispute_message') {
          sentMessage = jsonDecode(request.body) as Map<String, dynamic>;
          return respond('f1900000-0000-0000-0000-000000000088');
        }
        if (table == 'businesses' && request.method == 'PATCH') {
          profileUpdate = jsonDecode(request.body) as Map<String, dynamic>;
          return respond(profileVisible ? {'id': business} : null);
        }
        if (table == 'disputes') await disputeGate?.future;
        requests.add(request.url);
        if (table == 'token') {
          tokenRequests++;
          final expiresIn = issueExpiredToken ? -60 : 3600;
          issueExpiredToken = false;
          String encode(Object value) => base64Url
              .encode(utf8.encode(jsonEncode(value)))
              .replaceAll('=', '');
          final token =
              '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': owner, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + expiresIn})}.test';
          return respond({
            'access_token': token,
            'refresh_token': 'test-refresh',
            'token_type': 'bearer',
            'expires_in': expiresIn,
            'user': {
              'id': owner,
              'aud': 'authenticated',
              'role': 'authenticated',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': {},
              'user_metadata': {},
            },
          });
        }
        if (table == failingTable) {
          return respond({
            'code': '503',
            'message': 'simulated pull failure',
          }, 503);
        }
        if (table == 'currencies' && largeCurrencyPage) {
          final offset = int.parse(
            request.url.queryParameters['offset'] ?? '0',
          );
          return respond(
            List.generate(
              offset == 0
                  ? 500
                  : offset == 500
                  ? 1
                  : 0,
              (i) => {
                'code': 'T${offset + i}',
                'name': 'Test currency',
                'symbol': 'T',
                'decimal_scale': 4,
                'is_active': true,
              },
            ),
          );
        }
        if (table == 'business_members') {
          return respond([
            {
              'businesses': {
                'id': business,
                'owner_user_id': owner,
                'name': 'Sync test shop',
                'business_type': 'grocery',
                'currency_code': 'YER',
                'created_at': '2026-01-01T00:00:00Z',
              },
            },
          ]);
        }
        if (table == 'begin_merchant_sync_snapshot') {
          if (releasePull != null) {
            if (!pullEntered!.isCompleted) pullEntered!.complete();
            await releasePull!.future;
          }
          snapshotParams = jsonDecode(request.body) as Map<String, dynamic>;
          final raw = <Map<String, dynamic>>[
            if (contactCustomer)
              {
                'kind': 'customer',
                'payload': {
                  'id': 'f1900000-0000-0000-0000-000000000090',
                  'business_id': business,
                  'local_display_name': 'Contact sync',
                  'updated_at': '2026-10-19T00:00:00Z',
                  'is_archived': archivedCustomer,
                },
              },
            {
              'kind': 'state',
              'payload': {
                'entry_id': 'old-entry',
                'confirmation_status': 'confirmed',
                'dispute_status': 'resolved',
                'is_reversed': true,
              },
            },
          ];
          if (largeSnapshot) {
            raw.addAll(
              List.generate(
                501,
                (i) => {
                  'kind': 'state',
                  'payload': {
                    'entry_id': 'old-$i',
                    'confirmation_status': 'confirmed',
                    'dispute_status': 'resolved',
                    'is_reversed': true,
                  },
                },
              ),
            );
          }
          snapshotItems = [
            for (var i = 0; i < raw.length; i++) {...raw[i], 'ordinal': i + 1},
          ];
          return respond({
            'snapshot_id': 'f1900000-0000-0000-0000-000000000099',
            'item_count': snapshotItems.length,
          });
        }
        if (table == 'read_merchant_sync_snapshot') {
          final after = (jsonDecode(request.body) as Map)['p_after'] as int;
          if (failSnapshotTail && after >= 500) {
            return respond({
              'code': '503',
              'message': 'Last snapshot page unavailable',
            }, 503);
          }
          return respond(
            snapshotItems
                .where((r) => (r['ordinal'] as int) > after)
                .take(500)
                .toList(),
          );
        }
        if (table == 'mutate_customer_profile') {
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          profileRequests.add(payload);
          return respond({
            payload['p_action'] == 'archive' ? 'archived' : 'updated': true,
          });
        }
        if (table == 'business_customers' && contactCustomer) {
          return respond([
            {
              'id': 'f1900000-0000-0000-0000-000000000090',
              'business_id': business,
              'local_display_name': 'Contact sync',
              'updated_at': '2026-10-19T00:00:00Z',
              'is_archived': archivedCustomer,
            },
          ]);
        }
        if (table == 'customer-directory') {
          return respond({
            'businessCustomerId': 'f1900000-0000-0000-0000-000000000091',
          });
        }
        if (table == 'create_ledger_entry') {
          sentDebt = jsonDecode(request.body) as Map<String, dynamic>;
          return respond('f1900000-0000-0000-0000-000000000092');
        }
        if (table == 'ledger_entry_state') {
          return respond([
            {
              'entry_id': 'old-entry',
              'confirmation_status': 'confirmed',
              'dispute_status': 'resolved',
              'is_reversed': true,
            },
          ]);
        }
        if (table == 'customer-contacts') {
          final ids = (jsonDecode(request.body) as Map)['customerIds'] as List;
          return respond({
            'contacts': ids
                .map(
                  (id) => {'businessCustomerId': id, 'phone': '+967777123456'},
                )
                .toList(),
          });
        }
        if (table == 'businesses') return respond({'currency_code': 'YER'});
        if (table == 'resolve_dispute') {
          resolutionRequest = jsonDecode(request.body) as Map<String, dynamic>;
          if (resolutionSent != null && !resolutionSent!.isCompleted) {
            resolutionSent!.complete();
          }
          return respond(
            resolutionResultMissing ||
                    resolutionRequest?['p_resolution'] == 'rejected'
                ? null
                : 'f1900000-0000-0000-0000-000000000071',
          );
        }
        if (withDispute && table == 'disputes') {
          return respond([
            {
              'id': 'f1900000-0000-0000-0000-000000000070',
              'entry_id': 'old-entry',
              'business_id': business,
              'customer_id': owner,
              'reason': 'wrong_amount',
              'description': 'التحقق من المبلغ',
              'created_at': '2026-10-22T00:00:00Z',
              'dispute_state': {
                'status': 'resolved',
                'resolution_note': 'تصحيح',
              },
            },
            {
              'id': 'f1900000-0000-0000-0000-000000000075',
              'entry_id': 'new-entry',
              'business_id': business,
              'customer_id': owner,
              'reason': 'wrong_amount',
              'description': 'اعتراض جديد',
              'created_at': '2026-10-22T01:00:00Z',
              'dispute_state': {'status': 'awaiting_merchant'},
            },
          ]);
        }
        if (withDispute &&
            table == 'dispute_messages' &&
            request.url.queryParameters['dispute_id'] ==
                'eq.f1900000-0000-0000-0000-000000000070') {
          return respond([
            {
              'id': 'f1900000-0000-0000-0000-000000000072',
              'dispute_id': 'f1900000-0000-0000-0000-000000000070',
              'sender_user_id': owner,
              'message': 'رسالة من الخادم',
              'created_at': '2026-10-22T00:00:00Z',
            },
          ]);
        }
        if (table == 'sync_checkpoints') return respond(null);
        return respond([]);
      }),
    );
    await client.auth.signInWithPassword(
      email: 'sync@example.test',
      password: 'password',
    );
    engine = SyncEngine.forTesting(
      client: client,
      isOnline: () async => true,
      now: () => now,
    );
    final subscription = engine.progressStream.listen(events.add);
    addTearDown(() async {
      await subscription.cancel();
      engine.dispose();
      await client.dispose();
    });
  });

  test(
    'old profile queue only sends editable columns and requires confirmation',
    () async {
      const request = 'f1900000-0000-0000-0000-000000000091';
      await AppDatabase.instance.enqueueMutation(
        commandType: 'update_business_profile',
        clientRequestId: request,
        localRefId: business,
        payload: {
          'businessId': business,
          'name': 'Updated shop',
          'country_code': 'SA',
          'updated_at': '2026-01-01T00:00:00Z',
          'owner_user_id': 'forbidden',
        },
      );
      expect(await engine.triggerSync(), isTrue);
      expect(profileUpdate, {'name': 'Updated shop', 'country_code': 'SA'});
      expect(
        await AppDatabase.instance.getMutationByClientRequestId(request),
        isNull,
      );
    },
  );

  test('an invisible profile update stays queued as a failure', () async {
    profileVisible = false;
    const request = 'f1900000-0000-0000-0000-000000000092';
    addTearDown(() => AppDatabase.instance.removeMutation(request));
    await AppDatabase.instance.enqueueMutation(
      commandType: 'update_business_profile',
      clientRequestId: request,
      localRefId: business,
      payload: {'businessId': business, 'name': 'Unauthorized'},
    );
    expect(await engine.triggerSync(), isFalse);
    expect(
      (await AppDatabase.instance.getMutationByClientRequestId(
        request,
      ))?['status'],
      'dead_letter',
    );
  });

  test(
    'deployment recovery preserves message request IDs and awaits server capability',
    () async {
      const request = 'f1900000-0000-0000-0000-000000000093';
      addTearDown(() => AppDatabase.instance.removeMutation(request));
      final store = AppDatabase.instance;
      await store.enqueueMutation(
        commandType: 'add_dispute_message',
        clientRequestId: request,
        payload: {
          'p_dispute_id': 'dispute',
          'p_message': 'queued reply',
          'p_client_request_id': request,
          'p_sender_workspace': 'merchant',
        },
      );
      await store.markMutationDeadLetter(
        request,
        attemptCount: 1,
        error: 'Could not find the function',
        errorCode: 'PGRST202',
      );
      contractReady = false;
      expect(await engine.triggerSync(), isFalse);
      expect(sentMessage, isNull);
      expect(
        (await store.getMutationByClientRequestId(request))?['status'],
        'dead_letter',
      );
      contractReady = true;
      expect(await engine.triggerSync(), isTrue);
      expect(sentMessage?['p_client_request_id'], request);
      expect(sentMessage?['p_sender_workspace'], 'merchant');
      expect(await store.getMutationByClientRequestId(request), isNull);
    },
  );

  test(
    'deployment repair retries each request only once and leaves other denials alone',
    () async {
      final store = AppDatabase.instance;
      const repaired = 'f1900000-0000-0000-0000-000000000094';
      const denied = 'f1900000-0000-0000-0000-000000000095';
      addTearDown(() async {
        await store.removeMutation(repaired);
        await store.removeMutation(denied);
      });
      for (final request in [repaired, denied]) {
        await store.enqueueMutation(
          commandType: 'update_business_profile',
          clientRequestId: request,
          payload: {'businessId': business, 'name': 'profile'},
        );
        await store.markMutationDeadLetter(
          request,
          attemptCount: 1,
          error: request == repaired
              ? 'permission denied for table businesses'
              : 'Not authorized',
          errorCode: '42501',
        );
      }
      expect(await store.recoverDeploymentContractFailures(), 1);
      expect(
        (await store.getMutationByClientRequestId(denied))?['status'],
        'dead_letter',
      );
      await store.markMutationDeadLetter(
        repaired,
        attemptCount: 1,
        error: 'permission denied for table businesses',
        errorCode: '42501',
      );
      expect(await store.recoverDeploymentContractFailures(), 0);
    },
  );

  test(
    'merchant data is published before slow dispute hydration completes',
    () async {
      disputeGate = Completer<void>();
      var finished = false;
      final syncing = engine.triggerSync().then((value) {
        finished = true;
        return value;
      });
      try {
        for (
          var i = 0;
          i < 200 && !events.any((event) => event.dataChanged);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(events.any((event) => event.dataChanged), isTrue);
        expect(finished, isFalse);
        expect(events.any((event) => event.state == SyncState.synced), isFalse);
      } finally {
        disputeGate!.complete();
        await syncing;
      }
    },
  );

  test(
    'all disputes remain visible when a conversation download fails',
    () async {
      withDispute = true;
      failingTable = 'dispute_messages';
      expect(await engine.triggerSync(), isFalse);
      final disputes = await (await AppDatabase.instance.database).query(
        'local_disputes',
        where: 'business_id=?',
        whereArgs: [business],
      );
      expect(
        disputes.map((row) => row['id']),
        containsAll([
          'f1900000-0000-0000-0000-000000000070',
          'f1900000-0000-0000-0000-000000000075',
        ]),
      );
      expect(
        requests
            .where((uri) => uri.path.endsWith('/dispute_messages'))
            .map((uri) => uri.queryParameters['dispute_id'])
            .toSet(),
        hasLength(2),
      );
    },
  );

  test(
    'contact service failure does not hide newly downloaded disputes',
    () async {
      addTearDown(() async {
        final db = await AppDatabase.instance.database;
        const customer = 'f1900000-0000-0000-0000-000000000090';
        await db.delete(
          'local_sync_state',
          where: 'key=?',
          whereArgs: ['contact:$customer'],
        );
        await db.delete(
          'local_business_customers',
          where: 'id=?',
          whereArgs: [customer],
        );
      });
      withDispute = true;
      contactCustomer = true;
      failingTable = 'customer-contacts';
      expect(await engine.triggerSync(), isFalse);
      final disputes = await (await AppDatabase.instance.database).query(
        'local_disputes',
        where: 'business_id=?',
        whereArgs: [business],
      );
      expect(
        disputes.map((row) => row['id']),
        contains('f1900000-0000-0000-0000-000000000075'),
      );
    },
  );

  test(
    'queued dispute resolution dispatches once and hydrates local messages',
    () async {
      withDispute = true;
      const requestId = 'f1900000-0000-0000-0000-000000000073';
      const disputeId = 'f1900000-0000-0000-0000-000000000070';
      final db = AppDatabase.instance;
      await db.enqueueMutation(
        commandType: 'resolve_dispute',
        clientRequestId: requestId,
        localRefId: disputeId,
        payload: {
          'p_dispute_id': disputeId,
          'p_resolution': 'partially_accepted',
          'p_resolution_note': 'تصحيح',
          'p_corrected_amount': 80,
          'p_client_request_id': requestId,
        },
      );
      expect(await engine.triggerSync(), isTrue);
      expect(resolutionRequest?['p_client_request_id'], requestId);
      expect(resolutionRequest?['p_corrected_amount'], 80);
      expect(
        (await db.getPendingMutations()).where(
          (r) => r['command_type'] == 'resolve_dispute',
        ),
        isEmpty,
      );
      expect(
        (await db.getLocalDisputeMessages(disputeId)).single['message'],
        'رسالة من الخادم',
      );
      resolutionRequest = null;
      expect(await engine.triggerSync(), isTrue);
      expect(resolutionRequest, isNull);
      expect(await db.getLocalDisputeMessages(disputeId), hasLength(1));
    },
  );

  test(
    'financial dispute decision remains durable without server confirmation',
    () async {
      resolutionResultMissing = true;
      const requestId = 'f1900000-0000-0000-0000-000000000095';
      final db = AppDatabase.instance;
      addTearDown(() async {
        await (await db.database).delete(
          'offline_mutations_queue',
          where: 'client_request_id=?',
          whereArgs: [requestId],
        );
      });
      await db.enqueueMutation(
        commandType: 'resolve_dispute',
        clientRequestId: requestId,
        payload: {
          'p_dispute_id': 'f1900000-0000-0000-0000-000000000070',
          'p_resolution': 'partially_accepted',
          'p_resolution_note': 'تصحيح المبلغ',
          'p_corrected_amount': 80,
          'p_client_request_id': requestId,
        },
      );
      expect(await engine.triggerSync(), isFalse);
      expect(await db.getMutationByClientRequestId(requestId), isNotNull);
      expect(resolutionRequest?['p_client_request_id'], requestId);
    },
  );

  test(
    'save during a pull reruns immediately; concurrent requests coalesce',
    () async {
      pullEntered = Completer<void>();
      releasePull = Completer<void>();
      resolutionSent = Completer<void>();
      final syncing = engine.triggerSync();
      await pullEntered!.future.timeout(const Duration(seconds: 5));
      const requestId = 'f1900000-0000-0000-0000-000000000074';
      await AppDatabase.instance.enqueueMutation(
        commandType: 'resolve_dispute',
        clientRequestId: requestId,
        payload: {
          'p_dispute_id': 'f1900000-0000-0000-0000-000000000070',
          'p_resolution': 'rejected',
          'p_resolution_note': 'مراجعة',
          'p_client_request_id': requestId,
        },
      );
      await Future.wait(List.generate(5, (_) => engine.triggerSync()));
      expect(resolutionRequest, isNull);
      releasePull!.complete();
      await syncing;
      await resolutionSent!.future.timeout(const Duration(seconds: 5));
      // Let the requested cycle reach its read phase before asking it to stop.
      for (
        var i = 0;
        i < 100 &&
            requests
                    .where(
                      (r) => r.path.endsWith('/begin_merchant_sync_snapshot'),
                    )
                    .length <
                2;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await engine.pauseAndDrain();
      expect(
        requests.where((r) => r.path.endsWith('/resolve_dispute')),
        hasLength(1),
      );
      expect(
        requests.where((r) => r.path.endsWith('/begin_merchant_sync_snapshot')),
        hasLength(2),
      );
      expect(
        (await AppDatabase.instance.getPendingMutations()).where(
          (r) => r['client_request_id'] == requestId,
        ),
        isEmpty,
      );
    },
  );

  test(
    'pausing cancels a requested rerun before draining the current sync',
    () async {
      pullEntered = Completer<void>();
      releasePull = Completer<void>();
      final syncing = engine.triggerSync();
      await pullEntered!.future.timeout(const Duration(seconds: 5));
      expect(await engine.triggerSync(), isFalse);
      final paused = engine.pauseAndDrain();
      releasePull!.complete();
      await syncing;
      await paused;
      await Future<void>.delayed(Duration.zero);
      expect(
        requests.where((r) => r.path.endsWith('/begin_merchant_sync_snapshot')),
        hasLength(1),
      );
      expect(await engine.triggerSync(), isFalse);
    },
  );

  for (final table in [
    'currencies',
    'business_members',
    'begin_merchant_sync_snapshot',
    'read_merchant_sync_snapshot',
    'disputes',
  ]) {
    test(
      '$table failure cannot report success or replace last successful time',
      () async {
        expect(await engine.triggerSync(), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(events.last.state, SyncState.synced);
        final lastSuccess = events.last.lastSyncAt;
        expect(lastSuccess, now);
        events.clear();
        failingTable = table;
        now = now.add(const Duration(hours: 1));
        expect(await engine.triggerSync(), isFalse);
        await Future<void>.delayed(Duration.zero);
        expect(events.last.state, SyncState.error);
        expect(events.any((event) => event.state == SyncState.synced), isFalse);
        expect(events.last.lastSyncAt, lastSuccess);

        // A later successful pull must recover and advance the timestamp.
        failingTable = null;
        expect(await engine.triggerSync(), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(events.last.state, SyncState.synced);
        expect(events.last.lastSyncAt, now);
      },
    );
  }

  test('first failed pull has no successful sync timestamp', () async {
    failingTable = 'business_members';
    expect(await engine.triggerSync(), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(events.last.state, SyncState.error);
    expect(events.last.lastSyncAt, isNull);
  });

  test(
    'expired offline session refreshes automatically before pulling data',
    () async {
      issueExpiredToken = true;
      await client.auth.signInWithPassword(
        email: 'sync@example.test',
        password: 'password',
      );
      expect(client.auth.currentSession!.isExpired, isTrue);
      final before = tokenRequests;
      expect(await engine.triggerSync(), isTrue);
      expect(tokenRequests, before + 1);
      expect(client.auth.currentSession!.isExpired, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(events.last.state, SyncState.synced);
    },
  );

  test(
    'drains later pages and uses an inclusive local ledger boundary',
    () async {
      largeCurrencyPage = true;
      const boundary = '2026-10-19T00:00:00Z';
      await AppDatabase.instance.setLocalCheckpoint(business, boundary);
      expect(await engine.triggerSync(), isTrue);
      final currencies = requests
          .where((uri) => uri.path.endsWith('/currencies'))
          .toList();
      expect(currencies.length, 2);
      expect(currencies.last.queryParameters['offset'], '500');
      expect(snapshotParams?['p_cursor'], boundary);
      expect(
        requests.any((uri) => uri.path.endsWith('/sync_checkpoints')),
        isFalse,
      );
    },
  );

  test(
    'a successful pull with unsent work cannot advance successful sync time',
    () async {
      expect(await engine.triggerSync(), isTrue);
      await Future<void>.delayed(Duration.zero);
      final previous = events.last.lastSyncAt;
      const requestId = 'f1900000-0000-0000-0000-000000000003';
      await AppDatabase.instance.enqueueMutation(
        commandType: 'unknown_command_test',
        clientRequestId: requestId,
        payload: {},
      );
      addTearDown(() => AppDatabase.instance.removeMutation(requestId));
      now = now.add(const Duration(hours: 1));
      expect(await engine.triggerSync(), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(events.last.state, isNot(SyncState.synced));
      expect(events.last.lastSyncAt, previous);
    },
  );

  test(
    'optional checkpoint mirror failure does not discard a successful data pull',
    () async {
      failingTable = 'sync_checkpoints';
      expect(await engine.triggerSync(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(events.last.state, SyncState.synced);
      expect(events.last.lastSyncAt, now);
    },
  );
  test(
    'customer and dependent debt use server IDs in the same cycle',
    () async {
      final db = AppDatabase.instance;
      await db.upsertBusinessCustomer({
        'id': 'cust-cycle',
        'business_id': business,
        'local_display_name': 'Cycle',
        'sync_status': 'pending_insert',
      });
      final root = await db.enqueueMutation(
        commandType: 'customer_directory',
        payload: {'businessId': business, 'localCustomerId': 'cust-cycle'},
        localRefId: 'cust-cycle',
      );
      await db.saveLedgerEntryOptimistic(
        entry: {
          'id': 'entry-cycle',
          'business_id': business,
          'business_customer_id': 'cust-cycle',
          'entry_type': 'debt',
          'direction': 'debit',
          'amount': 10,
          'currency_code': 'YER',
          'description': 'Test debt',
          'occurred_at': '2026-10-19T00:00:00Z',
          'client_request_id': 'f1900000-0000-0000-0000-000000000093',
          'sync_status': 'pending_insert',
          'created_at': '2026-10-19T00:00:00Z',
        },
        commandType: 'create_ledger_entry',
        payload: {'p_business_customer_id': 'cust-cycle', 'p_amount': 10},
      );
      expect(await engine.triggerSync(), isTrue);
      expect(
        sentDebt?['p_business_customer_id'],
        'f1900000-0000-0000-0000-000000000091',
      );
      expect(await db.hasMutation(root), isFalse);
      expect(
        await db.hasMutation('f1900000-0000-0000-0000-000000000093'),
        isFalse,
      );
    },
  );
  test(
    'old ledger state changes and remote archive arrive beyond creation checkpoint',
    () async {
      final db = AppDatabase.instance;
      await db.upsertLedgerEntryFromServer({
        'id': 'old-entry',
        'business_id': business,
        'business_customer_id': 'old-customer',
        'entry_type': 'debt',
        'direction': 'debit',
        'amount': 10,
        'currency_code': 'YER',
        'description': 'Old',
        'occurred_at': '2020-01-01T00:00:00Z',
        'created_at': '2020-01-01T00:00:00Z',
        'client_request_id': 'old-request',
      });
      await db.setLocalCheckpoint(business, '2026-10-19T00:00:00Z');
      contactCustomer = true;
      archivedCustomer = true;
      expect(await engine.triggerSync(), isTrue);
      final entry = (await db.getLedgerEntries('old-customer')).single;
      expect(entry['confirmation_status'], 'confirmed');
      expect(entry['dispute_status'], 'resolved');
      expect(entry['is_reversed'], 1);
      expect(
        (await db.getCustomerById(
          'f1900000-0000-0000-0000-000000000090',
        ))!['is_archived'],
        1,
      );
      expect(
        (await db.getBusinessCustomers(
          business,
        )).any((r) => r['id'] == 'f1900000-0000-0000-0000-000000000090'),
        isFalse,
      );
    },
  );
  test(
    'protected contacts failure is visible and successful hydration is cached',
    () async {
      contactCustomer = true;
      failingTable = 'customer-contacts';
      expect(await engine.triggerSync(), isFalse);
      expect(
        await AppDatabase.instance.getContactsNeedingRefresh(business),
        isNotEmpty,
      );
      failingTable = null;
      expect(await engine.triggerSync(), isTrue);
      expect(
        (await AppDatabase.instance.getCustomerById(
          'f1900000-0000-0000-0000-000000000090',
        ))!['phone'],
        '+967777123456',
      );
      requests.clear();
      expect(await engine.triggerSync(), isTrue);
      expect(
        requests.any((uri) => uri.path.endsWith('/customer-contacts')),
        isFalse,
      );
    },
  );
  test(
    'a failed later snapshot page leaves customer data unchanged, then recovers',
    () async {
      final db = AppDatabase.instance;
      const id = 'f1900000-0000-0000-0000-000000000090';
      await db.upsertBusinessCustomer({
        'id': id,
        'business_id': business,
        'local_display_name': 'Before snapshot',
        'sync_status': 'synced',
      });
      contactCustomer = true;
      largeSnapshot = true;
      failSnapshotTail = true;
      expect(await engine.triggerSync(), isFalse);
      expect(
        (await db.getCustomerById(id))!['local_display_name'],
        'Before snapshot',
      );
      failSnapshotTail = false;
      expect(await engine.triggerSync(), isTrue);
      expect(
        (await db.getCustomerById(id))!['local_display_name'],
        'Contact sync',
      );
    },
  );
  test(
    'offline profile edit and archive dispatch in order with fixed request ids',
    () async {
      final db = AppDatabase.instance;
      const id = 'f1900000-0000-0000-0000-000000000090';
      await db.queueCustomerProfileChange(
        id,
        {'local_display_name': 'Offline edit'},
        {
          'p_business_customer_id': id,
          'p_action': 'update',
          'p_profile': {'display_name': 'Offline edit'},
        },
      );
      await db.queueCustomerProfileChange(
        id,
        {'is_archived': 1},
        {
          'p_business_customer_id': id,
          'p_action': 'archive',
          'p_profile': <String, dynamic>{},
        },
      );
      final commands = await db.getPendingMutations();
      final requestIds = commands
          .where((r) => r['command_type'] == 'mutate_customer_profile')
          .map((r) => r['client_request_id'])
          .toList();
      expect(await engine.triggerSync(), isTrue);
      expect(profileRequests.map((r) => r['p_action']).toList(), [
        'update',
        'archive',
      ]);
      expect(
        profileRequests.map((r) => r['p_request_id']).toList(),
        requestIds,
      );
      expect(
        (await db.getPendingMutations()).where(
          (r) => r['command_type'] == 'mutate_customer_profile',
        ),
        isEmpty,
      );
    },
  );
}
