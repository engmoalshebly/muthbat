import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Generates and persists one SQLCipher passphrase per local database file,
/// stored in Android Keystore / iOS Keychain — never in SharedPreferences or
/// application code. Losing this value makes the corresponding database file
/// permanently unreadable, matching SQLCipher's design.
class DbEncryptionKeyStore {
  DbEncryptionKeyStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _keyPrefix = 'muthbat_db_passphrase_v1_';

  /// Returns the passphrase for [databaseFileName], generating and storing a
  /// new random one on first use.
  Future<String> passphraseFor(String databaseFileName) async {
    final key = '$_keyPrefix$databaseFileName';
    final existing = await _storage.read(key: key);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = _generatePassphrase();
    await _storage.write(key: key, value: generated);
    return generated;
  }

  String _generatePassphrase() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }
}
