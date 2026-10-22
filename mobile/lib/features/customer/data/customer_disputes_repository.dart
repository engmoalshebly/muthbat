import 'package:flutter/foundation.dart';
import 'dart:convert';
import '../../../core/database/account_local_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/database/app_database.dart';
import '../../../core/security/cloud_session.dart';
import 'customer_cache.dart';

class CustomerDisputesRepository {
  CustomerDisputesRepository({SupabaseClient? client}) : _client = client;
  final SupabaseClient? _client;
  static final changes = ValueNotifier<int>(0);
  final _cache = CustomerCache();
  static const key = 'customer_disputes_v1';
  Future<List<Map<String, dynamic>>> local(String owner) async {
    final saved = await _cache.read(owner, key);
    return List<Map<String, dynamic>>.from(saved?['rows'] ?? []);
  }

  Future<void> sync(String owner) async {
    final client = _client ?? Supabase.instance.client;
    void check() {
      if (AppDatabase.instance.accountId != owner) {
        throw StateError('تغير الحساب');
      }
      requireCloudSession(client, owner);
    }

    check();
    final started = DateTime.now().toUtc().toIso8601String();
    String? after;
    final rows = <Map<String, dynamic>>[];
    do {
      final result = await client
          .rpc(
            'customer_disputes_page',
            params: {'p_after': after, 'p_limit': 50},
          )
          .timeout(const Duration(seconds: 20));
      check();
      final page = List<Map<String, dynamic>>.from(result as List);
      if (page.isEmpty) break;
      for (final item in page) {
        final id = item['id'] as String;
        if (after != null && id.compareTo(after) <= 0) {
          throw StateError('ترتيب الاعتراضات غير مكتمل');
        }
        after = id;
        rows.add(Map<String, dynamic>.from(item['document'] as Map));
      }
      if (page.length < 50) break;
    } while (true);
    check();
    rows.sort(
      (a, b) =>
          (b['created_at'] as String).compareTo(a['created_at'] as String),
    );
    final db = await accountLocalDatabase(owner);
    await db.execute(
      'CREATE TABLE IF NOT EXISTS customer_snapshots (cache_key TEXT PRIMARY KEY, document TEXT NOT NULL)',
    );
    await db.transaction((tx) async {
      final old = await tx.query(
        'customer_snapshots',
        where: 'cache_key=?',
        whereArgs: [key],
      );
      if (old.isNotEmpty) {
        final saved = jsonDecode(old.single['document'] as String) as Map;
        if ((saved['updated_at'] as String).compareTo(started) > 0) return;
      }
      await tx.rawInsert(
        'INSERT OR REPLACE INTO customer_snapshots(cache_key,document) VALUES(?,?)',
        [
          key,
          jsonEncode({'updated_at': started, 'rows': rows}),
        ],
      );
    });
    check();
    changes.value++;
  }
}

String customerDisputeStatus(String? status) => switch (status) {
  'awaiting_customer' => 'التاجر يحتاج ردك',
  'accepted' => 'قُبل الاعتراض وأُلغي أثر العملية',
  'partially_accepted' => 'قُبل الاعتراض وتم تصحيح المبلغ',
  'rejected' => 'رُفض الاعتراض وبقي المبلغ كما هو',
  'escalated' => 'الاعتراض قيد المتابعة',
  'closed' => 'الاعتراض مغلق',
  _ => 'وصل إلى التاجر • بانتظار الرد',
};

bool customerDisputeOpen(String? status) => {
  'open',
  'awaiting_merchant',
  'awaiting_customer',
  'escalated',
}.contains(status);
