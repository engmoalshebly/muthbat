import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PIN + optional biometric app lock. The PIN itself is never stored: only a
/// PBKDF2-HMAC-SHA256 hash (100,000 iterations) with a random per-device salt,
/// both in Android Keystore / iOS Keychain via [FlutterSecureStorage].
/// The protected PIN hash is also the enabled flag, so ordinary preferences
/// cannot disable the lock. Non-secret preferences (biometric toggle,
/// timeout and failed-attempt lockout) live in [SharedPreferences].
class AppLockService {
  AppLockService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static final instance = AppLockService();

  final FlutterSecureStorage _storage;

  static const _pinHashKey = 'app_lock_pin_hash_v1';
  static const _pinSaltKey = 'app_lock_pin_salt_v1';
  static const _biometricKey = 'app_lock_biometric_enabled_v1';
  static const _timeoutSecondsKey = 'app_lock_timeout_seconds_v1';
  static const _failedAttemptsKey = 'app_lock_failed_attempts_v1';
  static const _lockoutUntilKey = 'app_lock_lockout_until_v1';

  static const _pbkdf2Iterations = 100000;
  static const defaultTimeout = Duration(seconds: 30);
  static const maxAttemptsBeforeLockout = 5;
  static const lockoutDuration = Duration(seconds: 30);

  Future<bool> get isEnabled => isConfigured;

  Future<bool> get isConfigured async =>
      (await _storage.read(key: _pinHashKey)) != null;

  Future<bool> get biometricEnabled async =>
      (await SharedPreferences.getInstance()).getBool(_biometricKey) ?? false;

  Future<void> setBiometricEnabled(bool value) async {
    await (await SharedPreferences.getInstance()).setBool(_biometricKey, value);
  }

  Future<Duration> get autoLockTimeout async {
    final seconds = (await SharedPreferences.getInstance()).getInt(
      _timeoutSecondsKey,
    );
    return Duration(seconds: seconds ?? defaultTimeout.inSeconds);
  }

  Future<void> setAutoLockTimeout(Duration timeout) async {
    if (!const <int>{0, 30, 60, 300}.contains(timeout.inSeconds)) {
      throw ArgumentError.value(timeout, 'timeout', 'Unsupported timeout');
    }
    await (await SharedPreferences.getInstance()).setInt(
      _timeoutSecondsKey,
      timeout.inSeconds,
    );
  }

  /// Sets (or changes) the PIN and turns the lock on.
  Future<void> setPin(String pin) async {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw const FormatException('رمز القفل يجب أن يتكون من 6 أرقام');
    }
    final salt = _randomBytes(16);
    final hash = await _hashPin(pin, salt);
    await _storage.write(key: _pinSaltKey, value: base64Encode(salt));
    await _storage.write(key: _pinHashKey, value: base64Encode(hash));
  }

  /// Turns the lock off entirely and forgets the PIN. Callers must verify
  /// the current PIN/biometric themselves before calling this.
  Future<void> disable() async {
    await _storage.delete(key: _pinHashKey);
    await _storage.delete(key: _pinSaltKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_biometricKey, false);
    await prefs.remove(_failedAttemptsKey);
    await prefs.remove(_lockoutUntilKey);
  }

  Future<DateTime?> get lockedOutUntil async {
    final millis = (await SharedPreferences.getInstance()).getInt(
      _lockoutUntilKey,
    );
    if (millis == null) return null;
    final until = DateTime.fromMillisecondsSinceEpoch(millis);
    if (until.isAfter(DateTime.now())) return until;
    await (await SharedPreferences.getInstance()).remove(_lockoutUntilKey);
    return null;
  }

  Future<bool> verifyPin(String pin) async {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) return false;
    if (await lockedOutUntil != null) return false;
    final saltB64 = await _storage.read(key: _pinSaltKey);
    final hashB64 = await _storage.read(key: _pinHashKey);
    if (saltB64 == null || hashB64 == null) return false;
    final candidate = await _hashPin(pin, base64Decode(saltB64));
    final matches = _constantTimeEquals(candidate, base64Decode(hashB64));
    final prefs = await SharedPreferences.getInstance();
    if (matches) {
      await prefs.remove(_failedAttemptsKey);
      await prefs.remove(_lockoutUntilKey);
    } else {
      final attempts = (prefs.getInt(_failedAttemptsKey) ?? 0) + 1;
      await prefs.setInt(_failedAttemptsKey, attempts);
      if (attempts >= maxAttemptsBeforeLockout) {
        await prefs.setInt(
          _lockoutUntilKey,
          DateTime.now().add(lockoutDuration).millisecondsSinceEpoch,
        );
        await prefs.remove(_failedAttemptsKey);
      }
    }
    return matches;
  }

  Future<List<int>> _hashPin(String pin, List<int> salt) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _pbkdf2Iterations,
      bits: 256,
    );
    final key = await kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    return key.extractBytes();
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
