import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/features/customer/data/customer_disputes_repository.dart';
import 'package:muthbat/features/customer/data/customer_repository.dart';
import 'package:muthbat/features/customer/data/customer_outbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = 'f1960000-0000-0000-0000-000000000001';
  const other = 'f1960000-0000-0000-0000-000000000002';
  late SupabaseClient client;
  var failPage = false, replyClosed = false;
  final actions = <Map<String, dynamic>>[];
  final store = AppDatabase.instance;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp(
      'dispute-followup-',
    );
    await databaseFactoryFfi.setDatabasesPath(directory.path);
    await store.bindAccount(owner);
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
        if (request.url.path.endsWith('/token')) {
          return respond({
            'access_token': 'test-token',
            'refresh_token': 'refresh',
            'expires_in': 3600,
            'token_type': 'bearer',
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
        if (request.url.path.endsWith('/customer_disputes_page')) {
          final offset = payload['p_after'] == null
              ? 0
              : int.parse(payload['p_after'] as String) + 1;
          if (failPage && offset > 0) {
            return respond({'code': '503', 'message': 'unavailable'}, 503);
          }
          return respond(
            List.generate(
              offset == 0
                  ? 50
                  : offset == 50
                  ? 1
                  : 0,
              (i) {
                final id = (offset + i).toString().padLeft(4, '0');
                return {
                  'id': id,
                  'document': {
                    'id': id,
                    'entry_id': 'entry-$id',
                    'status': 'awaiting_customer',
                    'business_name': 'متجري',
                    'description': 'اعتراض',
                    'created_at': '2026-10-22T00:00:00Z',
                    'entry': {'amount': 100, 'currency_code': 'YER'},
                    'messages': [
                      {
                        'id': 'message-$id',
                        'message': 'رد التاجر',
                        'sender_user_id': other,
                      },
                    ],
                  },
                };
              },
            ),
          );
        }
        if (request.url.path.endsWith('/submit_customer_action')) {
          actions.add(payload);
          if (replyClosed) {
            return respond({
              'code': '55000',
              'message': 'Dispute is already resolved',
            }, 400);
          }
          return respond({'completed': true});
        }
        throw StateError('Unexpected request ${request.url}');
      }),
    );
    await client.auth.signInWithPassword(
      email: 'test@example.test',
      password: 'password',
    );
  });
  tearDownAll(() async {
    await client.dispose();
    await store.lockAccount();
  });
  test(
    'all pages and merchant messages persist; failed page cannot replace complete local data; accounts stay isolated',
    () async {
      final repo = CustomerDisputesRepository(client: client);
      await repo.sync(owner);
      expect(await repo.local(owner), hasLength(51));
      expect((await repo.local(owner)).first['messages'], hasLength(1));
      failPage = true;
      await expectLater(repo.sync(owner), throwsA(anything));
      expect(await repo.local(owner), hasLength(51));
      await store.lockAccount();
      await store.bindAccount(owner);
      expect(await repo.local(owner), hasLength(51));
      await store.bindAccount(other);
      expect(await repo.local(other), isEmpty);
      expect(await repo.local(owner), isEmpty);
      await expectLater(repo.sync(owner), throwsStateError);
      await store.bindAccount(owner);
    },
  );
  test(
    'offline replies retain the original receipt, rejected closed replies show actionable failure and can retry',
    () async {
      final repo = CustomerRepository(client: client);
      await repo.replyToDispute('dispute-1', '  توضيح للمتجر  ');
      final first = (await repo.pendingActions()).single;
      expect(jsonDecode(first['payload'] as String), {
        'kind': 'dispute_reply',
        'target_id': 'dispute-1',
        'message': 'توضيح للمتجر',
      });
      replyClosed = true;
      await repo.flushOutbox();
      final failed = (await repo.pendingActions()).single;
      expect(failed['status'], 'failed');
      expect(failed['error'], contains('تم إغلاق الاعتراض'));
      expect(failed['id'], first['id']);
      await repo.retryAction(first['id'] as String);
      replyClosed = false;
      await repo.flushOutbox();
      expect(await repo.pendingActions(), isEmpty);
      expect(actions.map((a) => a['p_request_id']).toSet(), {first['id']});
      expect(CustomerOutbox.changes.value, greaterThan(0));
    },
  );
  test(
    'customer-friendly states distinguish delivery, response and financial outcomes',
    () {
      expect(customerDisputeStatus('awaiting_customer'), 'التاجر يحتاج ردك');
      expect(customerDisputeStatus('rejected'), contains('بقي المبلغ'));
      expect(customerDisputeStatus('accepted'), contains('أُلغي أثر'));
      expect(customerDisputeOpen('rejected'), isFalse);
      expect(customerDisputeOpen('awaiting_customer'), isTrue);
    },
  );
}
