import 'dart:io';

import 'package:meta/meta.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// One-time, verified migration of a pre-existing plaintext SQLite file to a
/// SQLCipher-encrypted one, using SQLCipher's own `sqlcipher_export()` — the
/// documented safe path (no manual row copying, preserves indexes/triggers).
///
/// Safe to call on every app start: it is a no-op when [path] does not exist
/// or is already SQLCipher-encrypted. Never deletes the original file outright
/// — it is kept alongside as `<path>.pre-encryption.bak` so a failed migration
/// never loses financial data.
Future<void> migratePlaintextSqliteToEncrypted({
  required String path,
  required String passphrase,
}) async {
  final file = File(path);
  if (!await file.exists()) return;
  if (await looksSqlCipherEncrypted(file)) return;

  final tmpPath = '$path.encrypting.tmp';
  final tmpFile = File(tmpPath);
  if (await tmpFile.exists()) await tmpFile.delete();

  final plainDb = await openDatabase(path);
  Map<String, int> beforeCounts;
  try {
    beforeCounts = await _tableRowCounts(plainDb);
    await plainDb.execute(
      "ATTACH DATABASE '${_escapeSqlLiteral(tmpPath)}' AS encrypted "
      "KEY '${_escapeSqlLiteral(passphrase)}'",
    );
    await plainDb.execute("SELECT sqlcipher_export('encrypted')");
    await plainDb.execute('DETACH DATABASE encrypted');
  } finally {
    await plainDb.close();
  }

  final encryptedDb = await openDatabase(tmpPath, password: passphrase);
  final Map<String, int> afterCounts;
  try {
    afterCounts = await _tableRowCounts(encryptedDb);
  } finally {
    await encryptedDb.close();
  }

  if (!_rowCountsMatch(beforeCounts, afterCounts)) {
    // Do not touch the original file — leave it exactly as it was.
    if (await tmpFile.exists()) await tmpFile.delete();
    throw StateError(
      'SQLCipher migration verification failed for $path: '
      'row counts before=$beforeCounts after=$afterCounts',
    );
  }

  final backupPath = '$path.pre-encryption.bak';
  await file.rename(backupPath);
  await tmpFile.rename(path);
}

/// SQLCipher-encrypted files have no readable "SQLite format 3\0" header —
/// they start with the first encrypted page instead. This avoids ever
/// attempting to open a file with the wrong assumption baked into a query.
@visibleForTesting
Future<bool> looksSqlCipherEncrypted(File file) async {
  const magic = [
    0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, //
    0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00, // "SQLite format 3\0"
  ];
  final raf = await file.open();
  try {
    final header = await raf.read(magic.length);
    if (header.length != magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (header[i] != magic[i]) return true;
    }
    return false;
  } finally {
    await raf.close();
  }
}

Future<Map<String, int>> _tableRowCounts(Database db) async {
  final tables = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
  );
  final counts = <String, int>{};
  for (final row in tables) {
    final name = row['name'] as String;
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM "$name"');
    counts[name] = (result.first['c'] as int?) ?? 0;
  }
  return counts;
}

bool _rowCountsMatch(Map<String, int> before, Map<String, int> after) {
  if (before.length != after.length) return false;
  for (final entry in before.entries) {
    if (after[entry.key] != entry.value) return false;
  }
  return true;
}

String _escapeSqlLiteral(String value) => value.replaceAll("'", "''");
