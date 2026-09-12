import 'package:flutter/material.dart';

import '../../core/security/app_lock_service.dart';
import 'app_lock_screen.dart';

/// Wraps the whole app (via `MaterialApp.builder`) and shows [AppLockScreen]
/// on top of whatever route is currently active — on cold start when the
/// lock is configured, and again after the app has been backgrounded for
/// longer than the configured auto-lock timeout.
class AppLockOverlay extends StatefulWidget {
  const AppLockOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<AppLockOverlay> createState() => _AppLockOverlayState();
}

class _AppLockOverlayState extends State<AppLockOverlay>
    with WidgetsBindingObserver {
  bool _locked = false;
  bool _checkingInitial = true;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInitialLock();
  }

  Future<void> _checkInitialLock() async {
    final locked = await _shouldBeLocked();
    if (mounted) {
      setState(() {
        _locked = locked;
        _checkingInitial = false;
      });
    }
  }

  Future<bool> _shouldBeLocked() async {
    final enabled = await AppLockService.instance.isEnabled;
    if (!enabled) return false;
    return AppLockService.instance.isConfigured;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pausedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      _handleResume();
    }
  }

  Future<void> _handleResume() async {
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt == null) return;
    if (!await _shouldBeLocked()) return;
    final timeout = await AppLockService.instance.autoLockTimeout;
    if (DateTime.now().difference(pausedAt) >= timeout && mounted) {
      setState(() => _locked = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_checkingInitial)
          const Positioned.fill(child: ColoredBox(color: Color(0xFF153E3A))),
        if (_locked)
          AppLockScreen(onUnlocked: () => setState(() => _locked = false)),
      ],
    );
  }
}
