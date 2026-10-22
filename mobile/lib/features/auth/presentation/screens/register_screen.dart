import 'package:muthbat/shared/widgets/top_notice.dart';
import 'package:flutter/material.dart';
import '../widgets/compact_auth_layout.dart';
import '../widgets/auth_role_tabs.dart';
import '../../../../core/config/env.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../controllers/auth_controller.dart';
import '../widgets/country_code_picker.dart';
import '../widgets/user_type_selector.dart';
import '../validators/auth_validators.dart';
import '../customer_entry_mode.dart';

/// واجهة إنشاء حساب جديد لمنصة «مُثبَت | MUTHBAT»
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key, this.customerMode = false});
  final bool customerMode;

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  late UserAccountType _selectedType;

  @override
  void initState() {
    super.initState();
    _selectedType = widget.customerMode
        ? UserAccountType.customer
        : UserAccountType.merchant;
  }

  CountryInfo _selectedCountry = supportedCountries[0];
  bool _agreedToTerms = false;
  bool _obscurePassword = true;

  String? _nameError;
  String? _phoneError;
  String? _passwordError;
  String? _confirmPasswordError;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _handleRegister() async {
    final name = _nameController.text.trim();
    final rawPhone = _phoneController.text.trim();
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    bool hasError = false;

    if (name.isEmpty) {
      setState(() => _nameError = 'يرجى إدخال الاسم الكامل أو اسم المحل');
      hasError = true;
    }

    if (rawPhone.isEmpty || rawPhone.length < 7) {
      setState(() => _phoneError = 'يرجى إدخال رقم هاتف صحيح');
      hasError = true;
    }

    if (password.isEmpty) {
      setState(() => _passwordError = 'يرجى تعيين كلمة السر');
      hasError = true;
    } else if (password.length < 8) {
      setState(() => _passwordError = 'كلمة السر يجب ألا تقل عن 8 خانات');
      hasError = true;
    }

    if (confirmPassword.isEmpty) {
      setState(() => _confirmPasswordError = 'يرجى تأكيد كلمة السر');
      hasError = true;
    } else if (confirmPassword != password) {
      setState(() => _confirmPasswordError = 'كلمتا السر غير متطابقتين');
      hasError = true;
    }

    if (!_agreedToTerms) {
      TopNotice.of(context).showSnackBar(
        const SnackBar(
          content: Text('يجب الموافقة على شروط الاستخدام للمتابعة'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    if (hasError) return;

    final strictNameError = AuthValidators.nameError(name);
    final strictPhoneError = AuthValidators.phoneError(
      raw: rawPhone,
      dialCode: _selectedCountry.dialCode,
    );
    final strictPasswordError = AuthValidators.passwordError(password);
    if (strictNameError != null ||
        strictPhoneError != null ||
        strictPasswordError != null) {
      setState(() {
        _nameError = strictNameError;
        _phoneError = strictPhoneError;
        _passwordError = strictPasswordError;
      });
      return;
    }

    setState(() {
      _nameError = null;
      _phoneError = null;
      _passwordError = null;
      _confirmPasswordError = null;
    });

    final fullPhone = AuthValidators.normalizePhone(
      raw: rawPhone,
      dialCode: _selectedCountry.dialCode,
    );
    final userType = _selectedType == UserAccountType.merchant
        ? 'merchant'
        : 'customer';

    final success = await ref
        .read(authControllerProvider.notifier)
        .registerStart(
          name: name,
          phone: fullPhone,
          password: password,
          userType: userType,
        );

    if (success && mounted) {
      final authState = ref.read(authControllerProvider);
      if (authState.status == AuthStatus.authenticated &&
          authState.userId != null) {
        await CustomerEntryMode.remember(
          authState.userId!,
          _selectedType == UserAccountType.customer,
        );
        if (!mounted) return;
      }
      Navigator.pushNamedAndRemoveUntil(
        context,
        authState.status == AuthStatus.otpSent
            ? AppRoutes.otp
            : authState.userType == 'customer'
            ? AppRoutes.customerHome
            : authState.requiresBusinessSetup
            ? AppRoutes.businessSetup
            : AppRoutes.merchantHome,
        (route) => false,
      );
    }
  }

  /// حساب قوة كلمة السر (الحد الأدنى المقبول 8 خانات)
  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final loading = auth.status == AuthStatus.loading;
    return CompactAuthLayout(
      title: 'إنشاء حساب',
      subtitle: 'بيانات بسيطة لبدء الاستخدام',
      showCard: false,
      children: [
        AuthRoleTabs(
          customerSelected: _selectedType == UserAccountType.customer,
          onChanged: loading
              ? null
              : (customer) => setState(
                  () => _selectedType = customer
                      ? UserAccountType.customer
                      : UserAccountType.merchant,
                ),
        ),
        const SizedBox(height: 26),
        TextField(
          controller: _nameController,
          enabled: !loading,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.name],
          decoration: compactAuthDecoration(
            _selectedType == UserAccountType.merchant ? 'اسم المنشأة' : 'اسمك',
            error: _nameError,
            fillColor: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _phoneController,
          enabled: !loading,
          keyboardType: TextInputType.phone,
          textDirection: TextDirection.ltr,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.telephoneNumberNational],
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
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          enabled: !loading,
          obscureText: _obscurePassword,
          autofillHints: const [AutofillHints.newPassword],
          textInputAction: TextInputAction.next,
          decoration: compactAuthDecoration(
            'كلمة المرور · 8 أحرف على الأقل',
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
        const SizedBox(height: 12),
        TextField(
          controller: _confirmPasswordController,
          enabled: !loading,
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) {
            if (!loading) _handleRegister();
          },
          decoration: compactAuthDecoration(
            'تأكيد كلمة المرور',
            error: _confirmPasswordError,
            fillColor: Colors.white,
          ),
        ),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text(
            'أوافق على شروط الاستخدام',
            style: TextStyle(fontSize: 12),
          ),
          value: _agreedToTerms,
          onChanged: loading
              ? null
              : (v) => setState(() => _agreedToTerms = v ?? false),
        ),
        if (!EnvConfig.phoneVerificationEnabled)
          const Text(
            'التحقق من الهاتف مؤجل. احفظ كلمة المرور؛ الاسترداد غير متاح حاليًا.',
            style: TextStyle(fontSize: 11),
          ),
        if (auth.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              auth.errorMessage!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: loading ? null : _handleRegister,
          child: Text(loading ? 'جارٍ الإنشاء…' : 'إنشاء الحساب'),
        ),
        TextButton(
          onPressed: loading
              ? null
              : () => Navigator.pushReplacementNamed(context, AppRoutes.login),
          child: const Text('لديك حساب؟ تسجيل الدخول'),
        ),
      ],
    );
  }
}
