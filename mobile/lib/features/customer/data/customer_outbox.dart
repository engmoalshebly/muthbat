import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../../../core/database/app_database.dart';

class CustomerOutbox {
  Future<Database> _database(String owner) async {
    if (AppDatabase.instance.accountId != owner) {
      throw StateError('الحساب المحلي مقفل');
    }
    final db = await AppDatabase.instance.database;
    if (AppDatabase.instance.accountId != owner) {
      throw StateError('تغير الحساب');
    }
    await db.execute(
      'CREATE TABLE IF NOT EXISTS customer_outbox (id TEXT PRIMARY KEY, target_id TEXT NOT NULL UNIQUE, payload TEXT NOT NULL, status TEXT NOT NULL, error TEXT, created_at TEXT NOT NULL)',
    );
    return db;
  }

  Future<String> enqueue(String owner, Map<String, dynamic> payload) async {
    final db = await _database(owner);
    return db.transaction((txn) async {
      final encoded = jsonEncode(payload);
      final target = payload['target_id'] as String;
      final existing = await txn.query(
        'customer_outbox',
        where: 'target_id=?',
        whereArgs: [target],
      );
      if (existing.isNotEmpty) {
        if (existing.single['payload'] != encoded) {
          throw StateError(
            'يوجد طلب سابق لهذه العملية. راجع حالة إرساله أولًا.',
          );
        }
        return existing.single['id'] as String;
      }
      final id = const Uuid().v4();
      await txn.insert('customer_outbox', {
        'id': id,
        'target_id': target,
        'payload': encoded,
        'status': 'pending',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      return id;
    });
  }

  Future<List<Map<String, dynamic>>> list(String owner) async =>
      (await _database(
        owner,
      )).query('customer_outbox', orderBy: 'created_at,id');

  Future<void> complete(String owner, String id) async {
    await (await _database(
      owner,
    )).delete('customer_outbox', where: 'id=?', whereArgs: [id]);
  }

  Future<void> fail(String owner, String id, String message) async {
    await (await _database(owner)).update(
      'customer_outbox',
      {'status': 'failed', 'error': message},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> retry(String owner, String id) async {
    await (await _database(owner)).update(
      'customer_outbox',
      {'status': 'pending', 'error': null},
      where: 'id=?',
      whereArgs: [id],
    );
  }
}
