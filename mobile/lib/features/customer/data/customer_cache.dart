import 'dart:convert';
import '../../../core/database/app_database.dart';

/// Account-bound snapshots only. Never substitutes for server authorization.
class CustomerCache {
  Future<Map<String, dynamic>?> read(String owner, String key) async {
    final db = AppDatabase.instance;
    if (db.accountId != owner) return null;
    final connection = await db.database;
    await connection.execute(
      'CREATE TABLE IF NOT EXISTS customer_snapshots (cache_key TEXT PRIMARY KEY, document TEXT NOT NULL)',
    );
    final rows = await connection.query(
      'customer_snapshots',
      where: 'cache_key = ?',
      whereArgs: [key],
    );
    if (db.accountId != owner || rows.isEmpty) return null;
    return jsonDecode(rows.single['document'] as String)
        as Map<String, dynamic>;
  }

  Future<void> write(
    String owner,
    String key,
    Map<String, dynamic> value,
  ) async {
    final db = AppDatabase.instance;
    if (db.accountId != owner) return;
    final connection = await db.database;
    if (db.accountId != owner) return;
    await connection.execute(
      'CREATE TABLE IF NOT EXISTS customer_snapshots (cache_key TEXT PRIMARY KEY, document TEXT NOT NULL)',
    );
    await connection.rawInsert(
      'INSERT OR REPLACE INTO customer_snapshots(cache_key,document) VALUES(?,?)',
      [key, jsonEncode(value)],
    );
  }
}
