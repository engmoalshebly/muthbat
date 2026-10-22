import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../../../core/database/account_local_store.dart';
import 'customer_repository.dart';
import 'models/customer_summary_model.dart';

/// Read projections in the existing account-bound SQLCipher database.
/// Only complete, authorized server snapshots replace a ledger scope.
class CustomerLocalStore {
  static final changes = ValueNotifier<int>(0);
  static final ledgerChanges = ValueNotifier<int>(0);
  Future<Database> _db(String owner) async {
    final db = await accountLocalDatabase(owner);
    await db.execute(
      'CREATE TABLE IF NOT EXISTS customer_snapshots '
      '(cache_key TEXT PRIMARY KEY, document TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS customer_local_accounts '
      '(relationship TEXT NOT NULL, currency TEXT NOT NULL, document TEXT NOT NULL, '
      'PRIMARY KEY(relationship,currency))',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS customer_local_entries '
      '(id TEXT PRIMARY KEY, relationship TEXT NOT NULL, currency TEXT NOT NULL, '
      'occurred_at TEXT NOT NULL, document TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS customer_local_entries_scope '
      'ON customer_local_entries(relationship,currency,occurred_at DESC,id DESC)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS customer_local_ledgers '
      '(relationship TEXT NOT NULL, currency TEXT NOT NULL, updated_at TEXT NOT NULL, '
      'summary TEXT NOT NULL, PRIMARY KEY(relationship,currency))',
    );
    return db;
  }

  Future<void> saveHome(String owner, CustomerReadSnapshot snapshot) async {
    final db = await _db(owner);
    await db.transaction((tx) async {
      final old = await tx.query(
        'customer_snapshots',
        where: 'cache_key=?',
        whereArgs: ['home'],
      );
      if (old.isNotEmpty) {
        final date = jsonDecode(old.single['document'] as String)['updated_at'];
        if (date is String &&
            DateTime.parse(date).isAfter(DateTime.parse(snapshot.updatedAt))) {
          return;
        }
      }
      await tx.delete('customer_local_accounts');
      for (final summary in snapshot.summaries) {
        await tx.insert('customer_local_accounts', {
          'relationship': summary.businessCustomerId,
          'currency': summary.currencyCode,
          'document': jsonEncode(summary.toMap()),
        });
      }
      // Drop projections for relationships no longer returned by the server.
      for (final table in [
        'customer_local_entries',
        'customer_local_ledgers',
      ]) {
        await tx.rawDelete(
          'DELETE FROM $table WHERE NOT EXISTS '
          '(SELECT 1 FROM customer_local_accounts a WHERE '
          'a.relationship=$table.relationship AND a.currency=$table.currency)',
        );
      }
      await tx.rawInsert(
        'INSERT OR REPLACE INTO customer_snapshots(cache_key,document) VALUES(?,?)',
        [
          'home',
          jsonEncode({
            'customer_id': snapshot.customerId,
            'updated_at': snapshot.updatedAt,
            'summaries': snapshot.summaries.map((s) => s.toMap()).toList(),
            'requests': snapshot.requests.map((s) => s.toMap()).toList(),
            'entries': snapshot.entries,
          }),
        ],
      );
    });
    changes.value++;
  }

  Future<CustomerBusinessSummary?> summary(
    String owner,
    String relationship,
    String? currency,
  ) async {
    final rows = await (await _db(owner)).query(
      'customer_local_accounts',
      where: currency == null
          ? 'relationship=?'
          : 'relationship=? AND currency=?',
      whereArgs: currency == null ? [relationship] : [relationship, currency],
      orderBy: 'currency',
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : CustomerBusinessSummary.fromMap(
            jsonDecode(rows.single['document'] as String)
                as Map<String, dynamic>,
          );
  }

  Future<({int ready, int total})> coverage(String owner) async {
    final db = await _db(owner);
    final rows = await db.rawQuery(
      'SELECT a.document AS account, l.summary AS ledger '
      'FROM customer_local_accounts a LEFT JOIN customer_local_ledgers l '
      'ON a.relationship=l.relationship AND a.currency=l.currency',
    );
    var ready = 0;
    for (final row in rows) {
      if (row['ledger'] == null) continue;
      final account = CustomerBusinessSummary.fromMap(
        jsonDecode(row['account'] as String),
      );
      final ledger = CustomerBusinessSummary.fromMap(
        jsonDecode(row['ledger'] as String),
      );
      if (account.entryCount == ledger.entryCount &&
          account.currentBalance == ledger.currentBalance &&
          account.lastEntryAt == ledger.lastEntryAt) {
        ready++;
      }
    }
    return (ready: ready, total: rows.length);
  }

  Future<void> saveLedger(
    String owner,
    CustomerReadSnapshot snapshot, {
    required String relationship,
    required String currency,
  }) async {
    final summary = snapshot.summaries.single;
    if (summary.businessCustomerId != relationship ||
        summary.currencyCode != currency ||
        snapshot.entries.any(
          (e) =>
              e['business_customer_id'] != relationship ||
              e['currency_code'] != currency,
        )) {
      throw StateError('كشف الحساب لا يطابق الحساب المحدد');
    }
    final db = await _db(owner);
    await db.transaction((tx) async {
      final old = await tx.query(
        'customer_local_ledgers',
        where: 'relationship=? AND currency=?',
        whereArgs: [relationship, currency],
      );
      final access = await tx.query(
        'customer_local_accounts',
        where: 'relationship=? AND currency=?',
        whereArgs: [relationship, currency],
      );
      if (access.isEmpty) {
        throw StateError('تغير ارتباط الحساب. حدّث بيانات العميل.');
      }
      if (old.isNotEmpty &&
          DateTime.parse(
            old.single['updated_at'] as String,
          ).isAfter(DateTime.parse(snapshot.updatedAt))) {
        return;
      }
      await tx.delete(
        'customer_local_entries',
        where: 'relationship=? AND currency=?',
        whereArgs: [relationship, currency],
      );
      final batch = tx.batch();
      for (final entry in snapshot.entries) {
        batch.insert('customer_local_entries', {
          'id': entry['id'],
          'relationship': relationship,
          'currency': currency,
          'occurred_at': entry['occurred_at'],
          'document': jsonEncode(entry),
        });
      }
      batch.rawInsert(
        'INSERT OR REPLACE INTO customer_local_ledgers '
        '(relationship,currency,updated_at,summary) VALUES(?,?,?,?)',
        [
          relationship,
          currency,
          snapshot.updatedAt,
          jsonEncode(summary.toMap()),
        ],
      );
      await batch.commit(noResult: true);
    });
    ledgerChanges.value++;
  }

  Future<CustomerReadSnapshot?> ledger(
    String owner,
    String relationship,
    String currency,
  ) async {
    final db = await _db(owner);
    return db.transaction((tx) async {
      final scopes = await tx.query(
        'customer_local_ledgers',
        where: 'relationship=? AND currency=?',
        whereArgs: [relationship, currency],
      );
      if (scopes.isEmpty) return null;
      final rows = await tx.query(
        'customer_local_entries',
        where: 'relationship=? AND currency=?',
        whereArgs: [relationship, currency],
        orderBy: 'occurred_at DESC,id DESC',
      );
      return CustomerReadSnapshot(
        customerId: null,
        updatedAt: scopes.single['updated_at'] as String,
        summaries: [
          CustomerBusinessSummary.fromMap(
            jsonDecode(scopes.single['summary'] as String),
          ),
        ],
        requests: const [],
        entries: rows
            .map(
              (e) => Map<String, dynamic>.from(
                jsonDecode(e['document'] as String),
              ),
            )
            .toList(),
      );
    });
  }

  Future<Map<String, dynamic>?> entry(String owner, String id) async {
    final rows = await (await _db(owner)).query(
      'customer_local_entries',
      where: 'id=?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : Map<String, dynamic>.from(
            jsonDecode(rows.single['document'] as String),
          );
  }
}
