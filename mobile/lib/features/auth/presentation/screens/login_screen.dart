import '../widgets/compact_auth_layout.dart';
import '../widgets/auth_role_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../core/config/env.dart';
import '../controllers/auth_controller.dart';
import '../widgets/country_code_picker.dart';
import '../validators/auth_validators.dart';
import '../customer_entry_mode.dart';
import '../workspace_preference.dart';

/// واجهة تسجيل الدخول الاحترافية لمنصة «مُثبَت | MUTHBAT»
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  CountryInfo _selectedCountry = supportedCountries[0];
  bool _obscurePassword = true;
  bool _customerMode = true;
  String? _phoneError;
  String? _passwordError;

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _handleLogin() async {
    final rawPhone = _phoneController.text.trim();
    final password = _passwordController.text;

    bool hasError = false;

    if (rawPhone.isEmpty) {
      setState(() => _phoneError = 'يرجى إدخال رقم الهاتف');
      hasError = true;
    } else if (rawPhone.length < 7) {
      setState(() => _phoneError = 'رقم الهاتف قصير جداً وغير مكتمل');
      hasError = true;
    }

    if (password.isEmpty) {
      setState(() => _passwordError = 'يرجى إدخال كلمة السر');
      hasError = true;
    } else if (password.length < 8) {
      setState(() => _passwordError = 'كلمة السر يجب ألا تقل عن 8 خانات');
      hasError = true;
    }

    if (hasError) return;

    final strictPhoneError = AuthValidators.phoneError(
      raw: rawPhone,
      dialCode: _selectedCountry.dialCode,
    );
    final strictPasswordError = AuthValidators.passwordError(password);
    if (strictPhoneError != null || strictPasswordError != null) {
      setState(() {
        _phoneError = strictPhoneError;
        _passwordError = strictPasswordError;
      });
      return;
    }

    setState(() {
      _phoneError = null;
      _passwordError = null;
    });

    final fullPhone = AuthValidators.normalizePhone(
      raw: rawPhone,
      dialCode: _selectedCountry.dialCode,
    );

    final success = await ref
        .read(authControllerProvider.notifier)
        .loginWithPassword(
          phone: fullPhone,
          password: password,
          merchantMode: !_customerMode,
        );

    if (success && mounted) {
      final authState = ref.read(authControllerProvider);
      final employee =
          authState.businessRole != null && authState.businessRole != 'owner';
      final customerMode = _customerMode && !employee;
      if (authState.userId != null) {
        await CustomerEntryMode.remember(authState.userId!, customerMode);
        await WorkspacePreference.save(
          authState.userId!,
          customerMode ? 'customer' : 'merchant',
        );
      }
      if (!mounted) return;
      if (!customerMode && authState.userType == 'merchant') {
        Navigator.pushNamedAndRemoveUntil(
          context,
          authState.requiresBusinessSetup
              ? AppRoutes.businessSetup
              : AppRoutes.merchantHome,
          (r) => false,
        );
      } else {
        Navigator.pushNamedAndRemoveUntil(
          context,
          AppRoutes.customerHome,
          (r) => false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final loading = auth.status == AuthStatus.loading;
    return CompactAuthLayout(
      title: 'تسجيل الدخول',
      subtitle: 'أدخل رقم هاتفك وكلمة المرور للوصول إلى حسابك.',
      showCard: false,
      children: [
        AuthRoleTabs(
          customerSelected: _customerMode,
          onChanged: loading
              ? null
              : (customer) => setState(() => _customerMode = customer),
        ),
        const SizedBox(height: 26),
        TextField(
          controller: _phoneController,
          enabled: !loading,
          keyboardType: TextInputType.phone,
          textDirection: TextDirection.ltr,
          autofillHints: const [AutofillHints.telephoneNumberNational],
          textInputAction: TextInputAction.next,
          decoration: compactAuthDecoration(
            'رقم الهاتف',
            error: _phoneError,
            fillColor: Colors.white,
            prefix: CountryCodePickerButton(
              selectedCountry: _selectedCountry,
              onSelected: (v) => setState(() => _selectedCountry = v),
            ),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _passwordController,
          enabled: !loading,
          obscureText: _obscurePassword,
          autofillHints: const [AutofillHints.password],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) {
            if (!loading) _handleLogin();
          },
          decoration: compactAuthDecoration(
            'كلمة المرور',
            error: _passwordError,
            fillColor: Colors.white,
            suffix: IconButton(
              tooltip: 'إظهار أو إخفاء كلمة المرور',
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
        ),
        if (EnvConfig.phoneVerificationEnabled)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              onPressed: loading
                  ? null
                  : () => Navigator.pushNamed(context, AppRoutes.recovery),
              child: const Text('نسيت كلمة المرور؟'),
            ),
          ),
        if (auth.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              auth.errorMessage!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: loading ? null : _handleLogin,
          child: Text(loading ? 'جارٍ الدخول…' : 'تسجيل الدخول'),
        ),
        TextButton(
          onPressed: loading
              ? null
              : () => Navigator.pushNamed(
                  context,
                  AppRoutes.register,
                  arguments: _customerMode ? 'customer' : 'merchant',
                ),
          child: const Text('ليس لديك حساب؟ إنشاء حساب'),
        ),
      ],
    );
  }
}
