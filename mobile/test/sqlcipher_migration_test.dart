import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/core/database/sqlcipher_migration.dart';

/// sqflite_sqlcipher has no Linux/desktop implementation, so the actual
/// SQLCipher open/export path in migratePlaintextSqliteToEncrypted can only
/// run on a real Android/iOS/macOS device. These tests cover everything that
/// does not require the native plugin: the byte-level guard that decides
/// whether a file needs migrating at all, and the no-op short-circuits that
/// keep the function safe to call unconditionally on every app start.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sqlcipher-migration-');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('a genuine plaintext SQLite header is not mistaken for encrypted', () async {
    final file = File('${tempDir.path}/plain.db');
    final header = Uint8List.fromList([
      0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, //
      0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00, // "SQLite format 3\0"
      ...List.filled(48, 0),
    ]);
    await file.writeAsBytes(header);

    expect(await looksSqlCipherEncrypted(file), isFalse);
  });

  test('random bytes (as an encrypted first page looks) are treated as encrypted', () async {
    final file = File('${tempDir.path}/encrypted.db');
    await file.writeAsBytes(Uint8List.fromList(List.filled(64, 0x7a)));

    expect(await looksSqlCipherEncrypted(file), isTrue);
  });

  test('a truncated file shorter than the magic header does not crash the check', () async {
    final file = File('${tempDir.path}/truncated.db');
    await file.writeAsBytes(Uint8List.fromList([0x53, 0x51]));

    // Too short to be a valid SQLite file either way; the check must return
    // a plain bool rather than throwing, so migration can still proceed and
    // fail loudly (not a database) instead of the guard itself crashing.
    expect(await looksSqlCipherEncrypted(file), isFalse);
  });

  test('migration is a no-op when the file does not exist yet', () async {
    final path = '${tempDir.path}/missing.db';

    await migratePlaintextSqliteToEncrypted(path: path, passphrase: 'unused');

    expect(await File(path).exists(), isFalse);
  });

  test(
    'migration is a no-op and leaves the file untouched when it already looks encrypted',
    () async {
      final path = '${tempDir.path}/already-encrypted.db';
      final original = Uint8List.fromList(List.filled(64, 0x11));
      await File(path).writeAsBytes(original);

      await migratePlaintextSqliteToEncrypted(
        path: path,
        passphrase: 'unused',
      );

      expect(await File(path).readAsBytes(), original);
      expect(await File('$path.encrypting.tmp').exists(), isFalse);
      expect(await File('$path.pre-encryption.bak').exists(), isFalse);
    },
  );
}
