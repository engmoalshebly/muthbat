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
import 'package:muthbat/features/notifications/notification_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'downloads all pages, uploads read receipts, resumes incrementally, preserves concurrent preference edits',
    () async {
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp(
        'notification-local-sync-',
      );
      await databaseFactoryFfi.setDatabasesPath(directory.path);
      const owner = 'f1950000-0000-0000-0000-000000000002';
      await AppDatabase.instance.bindAccount(owner);
      final repository = NotificationRepository();
      final server = List.generate(
        261,
        (i) => <String, dynamic>{
          'id': i.toString().padLeft(4, '0'),
          'user_id': owner,
          'title': 'إشعار $i',
          'body': 'نص الإشعار',
          'created_at': '2026-10-21T10:00:00Z',
          'read_at': null,
          'data': {'workspace': i.isEven ? 'customer' : 'merchant'},
        },
      );
      final queries = <Uri>[];
      final preferenceGate = Completer<void>();
      final preferenceRequest = Completer<void>();
      var pausePreference = false;
      final client = SupabaseClient(
        'https://example.test',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          http.Response respond(Object? value) => http.Response(
            jsonEncode(value),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
          if (request.url.path.endsWith('/token')) {
            return respond({
              'access_token': 'test-token',
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
          expect(
            request.url.queryParameters['user_id'] ?? 'eq.$owner',
            'eq.$owner',
          );
          if (request.url.path.endsWith('/notification_preferences')) {
            if (request.method == 'POST') return respond(null);
            if (pausePreference) {
              preferenceRequest.complete();
              await preferenceGate.future;
            }
            return respond({
              'user_id': owner,
              for (final k in NotificationRepository.preferenceKeys) k: true,
            });
          }
          if (request.url.path.endsWith('/notifications')) {
            if (request.method == 'PATCH') {
              final filter = request.url.queryParameters['id']!;
              final ids = filter
                  .substring(4, filter.length - 1)
                  .split(',')
                  .map((id) => id.replaceAll('"', ''))
                  .toSet();
              final rows = server.where((n) => ids.contains(n['id'])).toList();
              for (final row in rows) {
                row['read_at'] = jsonDecode(request.body)['read_at'];
              }
              return respond(rows.map((r) => {'id': r['id']}).toList());
            }
            queries.add(request.url);
            var rows = server.reversed.toList();
            final filter = request.url.queryParameters['or'];
            if (filter != null) {
              final before = RegExp(
                r'id.lt.([^,)]+)',
              ).firstMatch(filter)!.group(1)!;
              rows = rows
                  .where((r) => (r['id'] as String).compareTo(before) < 0)
                  .toList();
            }
            return respond(rows.take(250).toList());
          }
          throw StateError('Unexpected request ${request.url}');
        }),
      );
      await client.auth.signInWithPassword(
        email: 'test@example.test',
        password: 'password',
      );
      await repository.sync(owner, client);
      expect(queries, hasLength(2));
      expect(await repository.unread(owner, 'customer'), 131);
      expect(await repository.unread(owner, 'merchant'), 130);
      await repository.markRead(owner, 'customer', id: '0000');
      await repository.sync(owner, client);
      expect(server.first['read_at'], isNotNull);
      expect((await repository.find(owner, '0000'))!['read_at'], isNotNull);
      await repository.merge(owner, [
        {...server.first, 'read_at': null},
      ]);
      expect((await repository.find(owner, '0000'))!['read_at'], isNotNull);
      expect(
        queries
            .skip(2)
            .every(
              (q) =>
                  q.queryParameters['created_at'] == 'gte.2026-10-21T10:00:00Z',
            ),
        isTrue,
      );
      pausePreference = true;
      final sync = repository.sync(owner, client);
      await preferenceRequest.future;
      await repository.savePreference(owner, 'push_enabled', false);
      preferenceGate.complete();
      await sync;
      expect((await repository.preferences(owner))['push_enabled'], false);
      final saved = await (await AppDatabase.instance.database).query(
        'local_notification_preferences',
      );
      expect(saved.single['dirty'], 1);
      await client.dispose();
      await AppDatabase.instance.lockAccount();
    },
  );
}
