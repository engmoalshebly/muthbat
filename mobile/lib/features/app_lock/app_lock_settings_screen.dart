import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/security/app_lock_service.dart';
import '../../core/security/biometric_auth.dart';

class AppLockSettingsScreen extends StatefulWidget {
  const AppLockSettingsScreen({super.key});

  @override
  State<AppLockSettingsScreen> createState() => _AppLockSettingsScreenState();
}

class _AppLockSettingsScreenState extends State<AppLockSettingsScreen> {
  bool _loading = true;
  bool _saving = false;
  bool _enabled = false;
  bool _biometric = false;
  bool _biometricAvailable = false;
  int _timeoutSeconds = 30;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = AppLockService.instance;
    final enabled = await service.isEnabled;
    final biometric = await service.biometricEnabled;
    final timeout = await service.autoLockTimeout;
    final available = await BiometricAuth.instance.isAvailable;
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _biometric = biometric;
      _timeoutSeconds = const <int>{0, 30, 60, 300}.contains(timeout.inSeconds)
          ? timeout.inSeconds
          : 30;
      _biometricAvailable = available;
      _loading = false;
    });
  }

  Future<String?> _askPin({
    required bool confirm,
    required String title,
  }) async {
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: first,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  labelText: confirm ? 'رمز جديد من 6 أرقام' : 'رمز القفل',
                  errorText: error,
                ),
              ),
              if (confirm)
                TextField(
                  controller: second,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(labelText: 'تأكيد الرمز'),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                final pin = first.text;
                if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
                  setDialogState(() => error = 'أدخل 6 أرقام');
                } else if (confirm && pin != second.text) {
                  setDialogState(() => error = 'الرمزان غير متطابقين');
                } else {
                  Navigator.pop(dialogContext, pin);
                }
              },
              child: const Text('متابعة'),
            ),
          ],
        ),
      ),
    );
    first.dispose();
    second.dispose();
    return result;
  }

  Future<bool> _verifyCurrentPin() async {
    final pin = await _askPin(confirm: false, title: 'تحقق من الرمز الحالي');
    if (pin == null) return false;
    final ok = await AppLockService.instance.verifyPin(pin);
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('رمز القفل غير صحيح')));
    }
    return ok;
  }

  Future<void> _enableOrChangePin() async {
    if (_enabled && !await _verifyCurrentPin()) return;
    if (!mounted) return;
    final pin = await _askPin(
      confirm: true,
      title: _enabled ? 'تغيير رمز القفل' : 'تفعيل قفل التطبيق',
    );
    if (pin == null) return;
    setState(() => _saving = true);
    await AppLockService.instance.setPin(pin);
    if (!mounted) return;
    setState(() {
      _enabled = true;
      _saving = false;
    });
  }

  Future<void> _disable() async {
    if (!await _verifyCurrentPin()) return;
    await AppLockService.instance.disable();
    if (!mounted) return;
    setState(() {
      _enabled = false;
      _biometric = false;
    });
  }

  Future<void> _toggleBiometric(bool value) async {
    if (!_enabled || !_biometricAvailable) return;
    if (!await _verifyCurrentPin()) return;
    if (value) {
      final verified = await BiometricAuth.instance.authenticate(
        reason: 'فعّل فتح مُثبَت بالبصمة',
      );
      if (!verified) return;
    }
    await AppLockService.instance.setBiometricEnabled(value);
    if (mounted) setState(() => _biometric = value);
  }

  Future<void> _setTimeout(int? seconds) async {
    if (seconds == null) return;
    await AppLockService.instance.setAutoLockTimeout(
      Duration(seconds: seconds),
    );
    if (mounted) setState(() => _timeoutSeconds = seconds);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('قفل التطبيق والبصمة')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Icon(
                  Icons.phonelink_lock_rounded,
                  size: 54,
                  color: AppColors.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  _enabled ? 'قفل التطبيق مفعّل' : 'قفل التطبيق غير مفعّل',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'رمز القفل يحمي فتح التطبيق على هذا الجهاز، ولا يستبدل كلمة سر الحساب أو تشفير النسخة الاحتياطية.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _saving ? null : _enableOrChangePin,
                  icon: const Icon(Icons.password_rounded),
                  label: Text(
                    _enabled ? 'تغيير رمز القفل' : 'تفعيل برمز من 6 أرقام',
                  ),
                ),
                if (_enabled) ...[
                  const SizedBox(height: 12),
                  SwitchListTile(
                    value: _biometric,
                    onChanged: _biometricAvailable ? _toggleBiometric : null,
                    title: const Text('فتح بالبصمة أو Face ID'),
                    subtitle: Text(
                      _biometricAvailable
                          ? 'يتطلب التحقق بالرمز قبل التفعيل'
                          : 'غير متاح أو غير مهيأ على هذا الجهاز',
                    ),
                  ),
                  ListTile(
                    title: const Text('القفل التلقائي بعد مغادرة التطبيق'),
                    trailing: DropdownButton<int>(
                      value: _timeoutSeconds,
                      onChanged: _setTimeout,
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('فورًا')),
                        DropdownMenuItem(value: 30, child: Text('30 ثانية')),
                        DropdownMenuItem(value: 60, child: Text('دقيقة')),
                        DropdownMenuItem(value: 300, child: Text('5 دقائق')),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _disable,
                    icon: const Icon(Icons.lock_open_rounded),
                    label: const Text('إيقاف قفل التطبيق'),
                  ),
                ],
              ],
            ),
    );
  }
}
