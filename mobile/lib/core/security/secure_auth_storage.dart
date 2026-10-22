import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Native session storage. No plaintext fallback if the secure store is locked
/// or unavailable. The caller can still open its independent local notebook.
class SecureAuthVault {
  SecureAuthVault({required String supabaseUrl, FlutterSecureStorage? storage})
    : project = Uri.parse(supabaseUrl).host,
      _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              storageNamespace: 'muthbat_supabase_auth',
              resetOnError: false,
            ),
            iOptions: IOSOptions(
              accountName: 'muthbat.supabase.auth',
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
            mOptions: MacOsOptions(
              accountName: 'muthbat.supabase.auth',
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
          );

  final String project;
  final FlutterSecureStorage _storage;
  static const _removed = '__muthbat_auth_removed_v1__';
  Future<void> _tail = Future<void>.value();

  String get legacySessionKey => 'sb-${project.split('.').first}-auth-token';
  String _key(String legacyKey) => 'muthbat_auth_v1:$project:$legacyKey';

  // Serialize SDK writes/removals within each client, including migration.
  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => _exclusive(operation));
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    _requireNative();
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final lock = await File(
      '${directory.path}/auth-${Uri.encodeComponent(project)}.lock',
    ).open(mode: FileMode.append);
    try {
      // Foreground and Workmanager may initialize in different isolates.
      // Hold the same lock while importing, writing, or removing a session.
      await lock.lock(FileLock.blockingExclusive);
      return await operation();
    } finally {
      // Closing also releases the lock on exceptions and process termination.
      await lock.close();
    }
  }

  void _requireNative() {
    if (kIsWeb) {
      throw UnsupportedError('Native secure auth storage is required.');
    }
  }

  Future<void> _removeLegacy(String legacyKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (prefs.containsKey(legacyKey) && !await prefs.remove(legacyKey)) {
      throw StateError('Unable to remove legacy auth storage.');
    }
  }

  Future<void> _writeVerified(String legacyKey, String value) async {
    await _storage.write(key: _key(legacyKey), value: value);
    if (await _storage.read(key: _key(legacyKey)) != value) {
      throw StateError('Secure auth storage verification failed.');
    }
  }

  Future<String?> read(String legacyKey) => _serial(() async {
    _requireNative();
    var value = await _storage.read(key: _key(legacyKey));
    if (value == null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final legacy = prefs.getString(legacyKey);
      if (legacy == null) return null;
      // Keep the old value intact until the secure copy can be read back.
      await _writeVerified(legacyKey, legacy);
      value = legacy;
    }
    // Also finishes cleanup if a previous process stopped after writing.
    await _removeLegacy(legacyKey);
    return value == _removed ? null : value;
  });

  Future<void> write(String legacyKey, String value) => _serial(() async {
    _requireNative();
    await _writeVerified(legacyKey, value);
    await _removeLegacy(legacyKey);
  });

  Future<void> remove(String legacyKey) => _serial(() async {
    _requireNative();
    // A token-free tombstone prevents an interrupted cleanup from importing
    // a stale plaintext session on the next launch.
    await _writeVerified(legacyKey, _removed);
    await _removeLegacy(legacyKey);
  });
}

class SecureSupabaseLocalStorage extends LocalStorage {
  const SecureSupabaseLocalStorage(this.vault);
  final SecureAuthVault vault;

  @override
  Future<void> initialize() async {
    await vault.read(vault.legacySessionKey);
  }

  @override
  Future<String?> accessToken() => vault.read(vault.legacySessionKey);

  @override
  Future<bool> hasAccessToken() async => await accessToken() != null;

  @override
  Future<void> persistSession(String persistSessionString) =>
      vault.write(vault.legacySessionKey, persistSessionString);

  @override
  Future<void> removePersistedSession() => vault.remove(vault.legacySessionKey);
}

/// Keep the PKCE verifier out of SharedPreferences as well.
class SecurePkceStorage extends GotrueAsyncStorage {
  SecurePkceStorage(this.vault);
  final SecureAuthVault vault;

  @override
  Future<String?> getItem({required String key}) => vault.read(key);

  @override
  Future<void> setItem({required String key, required String value}) =>
      vault.write(key, value);

  @override
  Future<void> removeItem({required String key}) => vault.remove(key);
}

FlutterAuthClientOptions secureAuthOptions(String supabaseUrl) {
  final vault = SecureAuthVault(supabaseUrl: supabaseUrl);
  return FlutterAuthClientOptions(
    authFlowType: AuthFlowType.pkce,
    localStorage: SecureSupabaseLocalStorage(vault),
    pkceAsyncStorage: SecurePkceStorage(vault),
  );
}
