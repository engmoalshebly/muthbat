import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/database/account_local_store.dart';
import '../../core/database/app_database.dart';
import '../../core/security/cloud_session.dart';

/// The inbox, unread count, read receipts and preferences use local storage.
/// Only authenticated RLS queries may populate notification destinations.
class NotificationRepository {
  static final changes = ValueNotifier<int>(0);

  /// A push is a display hint only; it grants no account/ledger access.
  Future<void> cachePush(String owner, Map<String, dynamic> data) async {
    if (data['user_id'] != owner || data['notification_id'] is! String) return;
    if (await find(owner, data['notification_id'] as String) != null) return;
    await merge(owner, [
      {
        'id': data['notification_id'],
        'user_id': owner,
        'title': data['_title'] ?? 'إشعار الحساب',
        'body': data['_body'] ?? '',
        'created_at':
            data['_sent_at'] ?? DateTime.now().toUtc().toIso8601String(),
        'read_at': null,
        'entity_type': data['entity_type'],
        'entity_id': data['entity_id'],
        'data': data,
      },
    ]);
  }

  Future<Database> _db(String owner) async {
    final db = await accountLocalDatabase(owner);
    await db.execute(
      'CREATE TABLE IF NOT EXISTS local_notifications '
      '(id TEXT PRIMARY KEY, workspace TEXT NOT NULL, created_at TEXT NOT NULL, '
      'read_at TEXT, pending_read INTEGER NOT NULL DEFAULT 0, document TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS local_notifications_scope '
      'ON local_notifications(workspace,created_at DESC,id DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS local_notifications_unread '
      'ON local_notifications(workspace,read_at)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS local_notification_preferences '
      '(id INTEGER PRIMARY KEY CHECK(id=1), document TEXT NOT NULL, revision INTEGER NOT NULL, dirty INTEGER NOT NULL)',
    );
    return db;
  }

  Future<List<Map<String, dynamic>>> list(
    String owner,
    String workspace, {
    int offset = 0,
    int limit = 40,
  }) async {
    final rows = await (await _db(owner)).query(
      'local_notifications',
      where: 'workspace=?',
      whereArgs: [workspace],
      orderBy: 'created_at DESC,id DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_decode).toList();
  }

  Map<String, dynamic> _decode(Map<String, Object?> row) => {
    ...Map<String, dynamic>.from(jsonDecode(row['document'] as String)),
    'read_at': row['read_at'],
  };

  Future<Map<String, dynamic>?> find(String owner, String id) async {
    final rows = await (await _db(
      owner,
    )).query('local_notifications', where: 'id=?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _decode(rows.single);
  }

  Future<int> unread(String owner, String workspace) async {
    final rows = await (await _db(owner)).rawQuery(
      'SELECT COUNT(*) AS count FROM local_notifications WHERE workspace=? AND read_at IS NULL',
      [workspace],
    );
    return (rows.single['count'] as num).toInt();
  }

  Future<void> markRead(String owner, String workspace, {String? id}) async {
    await (await _db(owner)).update(
      'local_notifications',
      {'read_at': DateTime.now().toUtc().toIso8601String(), 'pending_read': 1},
      where: 'workspace=? AND read_at IS NULL${id == null ? '' : ' AND id=?'}',
      whereArgs: [workspace, ?id],
    );
    changes.value++;
  }

  Future<void> merge(String owner, List<Map<String, dynamic>> notices) async {
    if (notices.any((n) => n['user_id'] != owner)) {
      throw StateError('إشعار لحساب مختلف');
    }
    final db = await _db(owner);
    await db.transaction((tx) async {
      for (final notice in notices) {
        final data = notice['data'];
        final workspace = data is Map ? data['workspace'] : null;
        if (workspace != 'customer' && workspace != 'merchant') continue;
        final old = await tx.query(
          'local_notifications',
          where: 'id=?',
          whereArgs: [notice['id']],
          limit: 1,
        );
        final pending = old.isNotEmpty && old.single['pending_read'] == 1;
        await tx.rawInsert(
          'INSERT OR REPLACE INTO local_notifications '
          '(id,workspace,created_at,read_at,pending_read,document) VALUES(?,?,?,?,?,?)',
          [
            notice['id'],
            workspace,
            notice['created_at'],
            pending
                ? old.single['read_at']
                : (notice['read_at'] ??
                      (old.isEmpty ? null : old.single['read_at'])),
            pending ? 1 : 0,
            jsonEncode(notice),
          ],
        );
      }
    });
    changes.value++;
  }

  static const preferenceKeys = [
    'push_enabled',
    'financial_enabled',
    'disputes_enabled',
    'reminders_enabled',
  ];
  Future<Map<String, dynamic>> preferences(String owner) async {
    final rows = await (await _db(
      owner,
    )).query('local_notification_preferences');
    return rows.isEmpty
        ? {for (final k in preferenceKeys) k: true}
        : Map<String, dynamic>.from(
            jsonDecode(rows.single['document'] as String),
          );
  }

  Future<void> savePreference(String owner, String key, bool value) async {
    if (!preferenceKeys.contains(key)) throw ArgumentError.value(key);
    final db = await _db(owner);
    await db.transaction((tx) async {
      final rows = await tx.query('local_notification_preferences');
      final prefs = rows.isEmpty
          ? {for (final k in preferenceKeys) k: true}
          : Map<String, dynamic>.from(
              jsonDecode(rows.single['document'] as String),
            );
      prefs[key] = value;
      await tx.rawInsert(
        'INSERT OR REPLACE INTO local_notification_preferences '
        '(id,document,revision,dirty) VALUES(1,?,?,1)',
        [
          jsonEncode(prefs),
          rows.isEmpty ? 1 : (rows.single['revision'] as int) + 1,
        ],
      );
    });
    changes.value++;
  }

  Future<void> sync(String owner, SupabaseClient client) async {
    void check() {
      if (AppDatabase.instance.accountId != owner) {
        throw StateError('تغير الحساب');
      }
      requireCloudSession(client, owner);
    }

    check();
    final db = await _db(owner);
    final pending = await db.query(
      'local_notifications',
      where: 'pending_read=1',
    );
    final groups = <String, List<String>>{};
    for (final row in pending) {
      groups
          .putIfAbsent(row['read_at'] as String, () => [])
          .add(row['id'] as String);
    }
    for (final group in groups.entries) {
      for (var start = 0; start < group.value.length; start += 100) {
        check();
        final ids = group.value.skip(start).take(100).toList();
        final updated = await client
            .from('notifications')
            .update({'read_at': group.key})
            .eq('user_id', owner)
            .inFilter('id', ids)
            .select('id')
            .timeout(const Duration(seconds: 12));
        check();
        await db.transaction((tx) async {
          final batch = tx.batch();
          for (final row in updated) {
            batch.update(
              'local_notifications',
              {'pending_read': 0},
              where: 'id=? AND read_at=?',
              whereArgs: [row['id'], group.key],
            );
          }
          await batch.commit(noResult: true);
        });
      }
    }
    final preferences = await db.query('local_notification_preferences');
    final revision = preferences.isEmpty
        ? 0
        : preferences.single['revision'] as int;
    if (preferences.isNotEmpty && preferences.single['dirty'] == 1) {
      await client
          .from('notification_preferences')
          .upsert({
            'user_id': owner,
            ...Map<String, dynamic>.from(
              jsonDecode(preferences.single['document'] as String),
            ),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .timeout(const Duration(seconds: 12));
      check();
      await db.update(
        'local_notification_preferences',
        {'dirty': 0},
        where: 'id=1 AND revision=?',
        whereArgs: [revision],
      );
    } else {
      final cloud = await client
          .from('notification_preferences')
          .select()
          .eq('user_id', owner)
          .maybeSingle()
          .timeout(const Duration(seconds: 12));
      check();
      if (cloud != null) {
        await db.transaction((tx) async {
          final now = await tx.query('local_notification_preferences');
          if (now.isNotEmpty &&
              (now.single['dirty'] == 1 ||
                  now.single['revision'] != revision)) {
            return;
          }
          await tx.rawInsert(
            'INSERT OR REPLACE INTO local_notification_preferences '
            '(id,document,revision,dirty) VALUES(1,?,?,0)',
            [
              jsonEncode({for (final k in preferenceKeys) k: cloud[k] ?? true}),
              revision,
            ],
          );
        });
      }
    }
    final checkpoint = await db.query(
      'local_sync_state',
      where: 'key=?',
      whereArgs: ['notification_sync_v1'],
    );
    final since = checkpoint.isEmpty
        ? null
        : checkpoint.single['value'] as String;
    // Refresh old unread rows too: another device may have marked them read.
    if (since != null) {
      final unread = await db.query(
        'local_notifications',
        columns: ['id'],
        where: 'read_at IS NULL AND created_at<?',
        whereArgs: [since],
      );
      for (var start = 0; start < unread.length; start += 100) {
        check();
        final ids = unread
            .skip(start)
            .take(100)
            .map((r) => r['id'] as String)
            .toList();
        final rows = await client
            .from('notifications')
            .select()
            .eq('user_id', owner)
            .inFilter('id', ids)
            .timeout(const Duration(seconds: 15));
        check();
        await merge(owner, rows);
      }
    }
    // Keyset pagination prevents duplicates/skips while new notices arrive.
    // After the initial download only new notices and old unread rows are read.
    String? beforeDate, beforeId;
    String? newest;
    while (true) {
      check();
      var query = client.from('notifications').select().eq('user_id', owner);
      if (since != null) query = query.gte('created_at', since);
      if (beforeDate != null) {
        query = query.or(
          'created_at.lt.$beforeDate,and(created_at.eq.$beforeDate,id.lt.$beforeId)',
        );
      }
      final rows = await query
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(250)
          .timeout(const Duration(seconds: 15));
      check();
      if (newest == null && rows.isNotEmpty) {
        newest = rows.first['created_at'] as String;
      }
      await merge(owner, rows);
      if (rows.length < 250) break;
      beforeDate = rows.last['created_at'] as String;
      beforeId = rows.last['id'] as String;
    }
    check();
    if (newest != null) {
      await db.rawInsert(
        'INSERT OR REPLACE INTO local_sync_state(key,value) VALUES(?,?)',
        ['notification_sync_v1', newest],
      );
    }
  }
}
