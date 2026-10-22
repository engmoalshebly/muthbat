import 'package:sqflite_sqlcipher/sqflite.dart';
import 'app_database.dart';

/// Captures this account's encrypted connection. Never reuses a different
/// account's connection after an asynchronous operation.
Future<Database> accountLocalDatabase(String owner) async {
  final store = AppDatabase.instance;
  if (store.accountId != owner) throw StateError('الحساب المحلي مقفل');
  final db = await store.database;
  if (store.accountId != owner) throw StateError('تغير الحساب');
  return db;
}
