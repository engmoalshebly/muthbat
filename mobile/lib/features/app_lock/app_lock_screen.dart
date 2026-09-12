import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/security/app_lock_service.dart';
import '../../core/security/biometric_auth.dart';
import '../auth/presentation/widgets/pin_code_fields.dart';

/// Full-screen PIN/biometric gate. Rendered by [AppLockOverlay] on top of
/// whatever the app was showing — never pushed as a route, so there is no
/// back-navigation path around it.
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key, required this.onUnlocked});

  final VoidCallback onUnlocked;

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final _pinKey = GlobalKey<PinCodeFieldsState>();
  String? _error;
  bool _checking = false;
  bool _showBiometricButton = false;
  bool _autoPromptDone = false;

  @override
  void initState() {
    super.initState();
    AppLockService.instance.biometricEnabled.then((enabled) {
      if (!mounted) return;
      setState(() => _showBiometricButton = enabled);
      if (enabled) _tryBiometric(auto: true);
    });
  }

  Future<void> _tryBiometric({bool auto = false}) async {
    if (auto && _autoPromptDone) return;
    if (auto) _autoPromptDone = true;
    if (!await BiometricAuth.instance.isAvailable) return;
    final ok = await BiometricAuth.instance.authenticate(
      reason: 'افتح قفل التطبيق',
    );
    if (ok && mounted) widget.onUnlocked();
  }

  Future<void> _submitPin(String pin) async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    final lockedUntil = await AppLockService.instance.lockedOutUntil;
    if (lockedUntil != null) {
      final seconds = lockedUntil
          .difference(DateTime.now())
          .inSeconds
          .clamp(1, 999);
      if (mounted) {
        setState(() {
          _checking = false;
          _error = 'محاولات كثيرة خاطئة، حاول بعد $seconds ثانية';
        });
      }
      _pinKey.currentState?.clear();
      return;
    }
    final ok = await AppLockService.instance.verifyPin(pin);
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
      return;
    }
    setState(() {
      _checking = false;
      _error = 'رمز غير صحيح';
    });
    _pinKey.currentState?.clear();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Material(
          color: AppColors.primaryDark,
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.lock_outline_rounded,
                      color: Colors.white,
                      size: 44,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'أدخل رمز القفل',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Opacity(
                      opacity: _checking ? 0.5 : 1,
                      child: IgnorePointer(
                        ignoring: _checking,
                        child: PinCodeFields(
                          key: _pinKey,
                          length: 6,
                          onCompleted: _submitPin,
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ],
                    if (_showBiometricButton) ...[
                      const SizedBox(height: 24),
                      TextButton.icon(
                        onPressed: () => _tryBiometric(),
                        icon: const Icon(
                          Icons.fingerprint,
                          color: Colors.white,
                        ),
                        label: const Text(
                          'استخدام البصمة',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
