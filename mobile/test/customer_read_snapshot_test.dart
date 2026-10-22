import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/features/customer/data/customer_repository.dart';
import 'package:muthbat/features/customer/data/customer_ledger_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = 'c1940000-0000-0000-0000-000000000001';
  late SupabaseClient client;
  late CustomerRepository repo;
  final actions = <Map<String, dynamic>>[];
  var failPage = false, permanentFailure = false, temporaryFailure = false;
  var released = 0, pages = 0;
  Completer<void>? releaseGate;
  Future<void> waitForCleanup() async {
    for (var i = 0; i < 100 && released == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  final items = <Map<String, dynamic>>[];
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp(
      'customer-read-snapshot-',
    );
    await databaseFactoryFfi.setDatabasesPath(directory.path);
    await AppDatabase.instance.bindAccount(owner);
  });
  tearDownAll(() => AppDatabase.instance.lockAccount());
  setUp(() async {
    items.clear();
    actions.clear();
    released = 0;
    releaseGate = null;
    pages = 0;
    failPage = false;
    permanentFailure = false;
    temporaryFailure = false;
    await (await AppDatabase.instance.database).execute(
      'CREATE TABLE IF NOT EXISTS customer_outbox (id TEXT PRIMARY KEY, target_id TEXT NOT NULL UNIQUE, payload TEXT NOT NULL, status TEXT NOT NULL, error TEXT, created_at TEXT NOT NULL)',
    );
    await (await AppDatabase.instance.database).delete('customer_outbox');
    client = SupabaseClient(
      'https://example.test',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        http.Response respond(Object? value, [int status = 200]) =>
            http.Response(
              jsonEncode(value),
              status,
              headers: {'content-type': 'application/json'},
              request: request,
            );
        final path = request.url.path;
        if (path.endsWith('/token')) {
          String encode(Object value) => base64Url
              .encode(utf8.encode(jsonEncode(value)))
              .replaceAll('=', '');
          final token =
              '${encode({'alg': 'HS256'})}.${encode({'sub': owner, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.test';
          return respond({
            'access_token': token,
            'refresh_token': 'test-refresh',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': owner,
              'aud': 'authenticated',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': {},
              'user_metadata': {},
            },
          });
        }
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        if (path.endsWith('/begin_customer_read_snapshot')) {
          return respond({
            'snapshot_id': 'snapshot',
            'item_count': items.length,
          });
        }
        if (path.endsWith('/read_customer_read_snapshot')) {
          pages++;
          final after = payload['p_after'] as int;
          if (failPage && after >= 100) {
            return respond({
              'code': '503',
              'message': 'later page unavailable',
            }, 503);
          }
          // Deliberately cap below the requested page size: completion uses item_count.
          return respond(items.skip(after).take(100).toList());
        }
        if (path.endsWith('/release_customer_read_snapshot')) {
          released++;
          await releaseGate?.future;
          return respond(null);
        }
        if (path.endsWith('/submit_customer_action')) {
          actions.add(payload);
          if (actions.length == 1 && permanentFailure) {
            return respond({'code': '42501', 'message': 'revoked'}, 403);
          }
          if (actions.length == 1 && temporaryFailure) {
            return respond({'code': '503', 'message': 'unavailable'}, 503);
          }
          return respond({'completed': true});
        }
        throw StateError('Unexpected request: $path');
      }),
    );
    await client.auth.signInWithPassword(
      phone: '+967777123456',
      password: 'test-password',
    );
    repo = CustomerRepository(client: client);
  });
  tearDown(() async => client.dispose());
  void add(String kind, Map<String, dynamic> payload) => items.add({
    'ordinal': items.length + 1,
    'kind': kind,
    'payload': payload,
  });
  Map<String, dynamic> summary(int i) => {
    'business_customer_id': 'bc-$i',
    'business_id': 'shop-$i',
    'business_name': 'بقالة $i',
    'currency_code': 'YER',
    'current_balance': 1201,
    'entry_count': 1201,
  };
  Map<String, dynamic> entry(int i) => {
    'id': 'entry-$i',
    'business_customer_id': 'bc-0',
    'entry_type': 'debt',
    'direction': 'debit',
    'amount': 1,
    'currency_code': 'YER',
    'description': 'دين $i',
    'occurred_at': '2026-10-19T00:00:00Z',
    'confirmation_status': 'pending',
    'dispute_status': 'none',
    'is_reversed': false,
  };
  void metadata() => add('metadata', {
    'customer_id': 'customer',
    'updated_at': '2026-10-19T00:00:00Z',
  });
  test(
    'all shops, pending entries and invitations exceed server row cap without truncation',
    () async {
      metadata();
      for (var i = 0; i < 1201; i++) {
        add('summary', summary(i));
        add('entry', entry(i));
        add('request', {
          'id': 'request-$i',
          'business_name': 'بقالة $i',
          'status': 'pending',
        });
      }
      final snapshot = await repo.fetchHomeSnapshot();
      expect(snapshot.summaries.length, 1201);
      expect(snapshot.entries.length, 1201);
      expect(snapshot.requests.length, 1201);
      expect(pages, 37);
      await waitForCleanup();
      expect(released, 1);
    },
  );
  test(
    'later page failure rejects partial data and releases the snapshot',
    () async {
      metadata();
      for (var i = 0; i < 201; i++) {
        add('summary', summary(i));
      }
      failPage = true;
      await expectLater(
        repo.fetchHomeSnapshot(),
        throwsA(isA<PostgrestException>()),
      );
      await waitForCleanup();
      expect(released, 1);
    },
  );
  test(
    'a slow snapshot cleanup does not hold completed customer data',
    () async {
      metadata();
      releaseGate = Completer<void>();
      try {
        final snapshot = await repo.fetchHomeSnapshot().timeout(
          const Duration(seconds: 1),
        );
        expect(snapshot.updatedAt, isNotEmpty);
        await waitForCleanup();
        expect(released, 1);
        expect(releaseGate!.isCompleted, isFalse);
      } finally {
        releaseGate!.complete();
        await Future<void>.delayed(Duration.zero);
      }
    },
  );
  test(
    'full PDF loads all ledger pages independently of the visible 50 rows',
    () async {
      metadata();
      add('summary', summary(0));
      for (var i = 0; i < 1201; i++) {
        add('entry', entry(i));
      }
      final snapshot = await repo.fetchCompleteLedger(
        businessCustomerId: 'bc-0',
        currency: 'YER',
      );
      expect(snapshot.entries.length, 1201);
      final pdf = await customerLedgerPdf(
        summary: snapshot.summaries.single,
        entries: snapshot.entries,
        updatedAt: snapshot.updatedAt,
        isComplete: true,
      );
      expect(String.fromCharCodes(pdf.take(4)), '%PDF');
      expect(pdf.length, greaterThan(10000));
    },
  );
  Future<void> queueThree() async {
    for (var i = 0; i < 3; i++) {
      await repo.confirmEntry('entry-$i');
    }
  }

  test(
    'one flush sends multiple actions with their persisted receipt IDs',
    () async {
      await queueThree();
      final before = await repo.pendingActions();
      await repo.flushOutbox();
      expect(actions.map((e) => e['p_request_id']), before.map((e) => e['id']));
      expect(await repo.pendingActions(), isEmpty);
    },
  );
  test(
    'permanent failure is visible and does not block independent actions',
    () async {
      await queueThree();
      permanentFailure = true;
      await repo.flushOutbox();
      expect(actions.length, 3);
      expect((await repo.pendingActions()).single['status'], 'failed');
    },
  );
  test(
    'uncertain delivery stops batch and preserves original IDs for retry',
    () async {
      await queueThree();
      temporaryFailure = true;
      final before = await repo.pendingActions();
      await repo.flushOutbox();
      expect(actions.length, 1);
      expect(
        (await repo.pendingActions()).map((e) => e['id']),
        before.map((e) => e['id']),
      );
      temporaryFailure = false;
      actions.clear();
      await repo.flushOutbox();
      expect(await repo.pendingActions(), isEmpty);
    },
  );
}
