import 'package:local_auth/local_auth.dart';

/// Thin wrapper so the rest of the app never touches `local_auth` directly
/// and every failure mode (no hardware, not enrolled, user cancel, lockout)
/// collapses to a single boolean the UI can act on without inspecting
/// platform-specific exception types.
class BiometricAuth {
  BiometricAuth({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  static final instance = BiometricAuth();

  final LocalAuthentication _auth;

  Future<bool> get isAvailable async {
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      return supported && canCheck;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticate({required String reason}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}
