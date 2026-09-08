import 'package:muthbat/shared/widgets/top_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/custom_button.dart';
import '../controllers/auth_controller.dart';
import '../widgets/auth_text_field.dart';
import '../widgets/country_code_picker.dart';
import '../widgets/user_type_selector.dart';
import '../validators/auth_validators.dart';

/// واجهة إنشاء حساب جديد لمنصة «مُثبَت | MUTHBAT»
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  UserAccountType _selectedType = UserAccountType.merchant;
  CountryInfo _selectedCountry = supportedCountries[0];
  bool _agreedToTerms = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

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
      Navigator.pushNamedAndRemoveUntil(
        context,
        authState.requiresBusinessSetup
            ? AppRoutes.businessSetup
            : AppRoutes.merchantHome,
        (route) => false,
      );
    }
  }

  /// حساب قوة كلمة السر (الحد الأدنى المقبول 8 خانات)
  double _passwordStrength(String password) {
    if (password.isEmpty) return 0;
    double strength = 0;
    if (password.length >= 8) strength += 0.3;
    if (password.length >= 12) strength += 0.2;
    if (RegExp(r'[A-Z]').hasMatch(password)) strength += 0.15;
    if (RegExp(r'[0-9]').hasMatch(password)) strength += 0.15;
    if (RegExp(r'[!@#\$%\^&\*]').hasMatch(password)) strength += 0.2;
    return strength.clamp(0.0, 1.0);
  }

  Color _strengthColor(double strength) {
    if (strength < 0.3) return AppColors.error;
    if (strength < 0.6) return AppColors.warning;
    if (strength < 0.85) return AppColors.secondary;
    return AppColors.success;
  }

  String _strengthLabel(double strength) {
    if (strength < 0.3) return 'ضعيفة';
    if (strength < 0.6) return 'متوسطة';
    if (strength < 0.85) return 'جيدة';
    return 'قوية جداً';
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final isLoading = authState.status == AuthStatus.loading;
    final screenHeight = MediaQuery.of(context).size.height;
    final strength = _passwordStrength(_passwordController.text);

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: Stack(
        children: [
          // === الخلفية المتدرجة العلوية ===
          ClipPath(
            clipper: _TopCurveClipper(),
            child: Container(
              height: screenHeight * 0.30,
              decoration: const BoxDecoration(
                gradient: AppColors.brandGradient,
              ),
              child: Stack(
                children: [
                  Positioned(
                    top: -30,
                    left: -40,
                    child: Container(
                      width: 160,
                      height: 160,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.04),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // === المحتوى ===
          SafeArea(
            child: Column(
              children: [
                // --- AppBar شفاف ---
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Spacer(),
                      Text(
                        'حساب جديد',
                        style: AppTypography.titleMedium(
                          color: Colors.white,
                        ).copyWith(fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),

                // --- شريط تقدم بصري (Progress Steps) ---
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 40,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      _buildStep(1, 'البيانات', true),
                      Expanded(
                        child: Container(
                          height: 2,
                          color: Colors.white.withValues(alpha: 0.3),
                        ),
                      ),
                      _buildStep(2, 'التحقق', false),
                      Expanded(
                        child: Container(
                          height: 2,
                          color: Colors.white.withValues(alpha: 0.15),
                        ),
                      ),
                      _buildStep(3, 'التفعيل', false),
                    ],
                  ),
                ).animate().fadeIn(duration: 400.ms),

                const SizedBox(height: 8),

                // --- المحتوى القابل للتمرير ---
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // --- بطاقة اختيار نوع الحساب ---
                        Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(22),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.primary.withValues(
                                      alpha: 0.06,
                                    ),
                                    blurRadius: 20,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: AppColors.secondary.withValues(
                                            alpha: 0.1,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.person_outline_rounded,
                                          color: AppColors.secondary,
                                          size: 18,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'نوع الحساب',
                                        style: AppTypography.titleSmall(
                                          color: AppColors.textPrimary,
                                        ).copyWith(fontWeight: FontWeight.w700),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _buildTypeCard(
                                          icon: Icons.storefront_rounded,
                                          label: 'صاحب محل / تاجر',
                                          subtitle: 'إدارة الدفتر والزبائن',
                                          isSelected:
                                              _selectedType ==
                                              UserAccountType.merchant,
                                          onTap: () => setState(
                                            () => _selectedType =
                                                UserAccountType.merchant,
                                          ),
                                          color: AppColors.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _buildTypeCard(
                                          icon: Icons.person_rounded,
                                          label: 'عميل / زبون',
                                          subtitle: 'متابعة مشترياتي',
                                          isSelected:
                                              _selectedType ==
                                              UserAccountType.customer,
                                          onTap: () => setState(
                                            () => _selectedType =
                                                UserAccountType.customer,
                                          ),
                                          color: AppColors.secondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            )
                            .animate()
                            .fadeIn(duration: 400.ms)
                            .slideY(begin: 0.1, end: 0),

                        const SizedBox(height: 16),

                        // --- بطاقة بيانات التسجيل ---
                        Container(
                              padding: const EdgeInsets.all(22),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(24),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.primary.withValues(
                                      alpha: 0.08,
                                    ),
                                    blurRadius: 28,
                                    offset: const Offset(0, 10),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // الاسم
                                  _buildFieldLabel(
                                    _selectedType == UserAccountType.merchant
                                        ? 'اسم المحل أو التاجر'
                                        : 'الاسم الكامل',
                                    Icons.badge_outlined,
                                  ),
                                  const SizedBox(height: 8),
                                  AuthTextField(
                                    controller: _nameController,
                                    hintText:
                                        _selectedType ==
                                            UserAccountType.merchant
                                        ? 'مثال: تموينات الأمانة'
                                        : 'مثال: محمد علي أحمد',
                                    errorText: _nameError,
                                    onChanged: (_) {
                                      if (_nameError != null)
                                        setState(() => _nameError = null);
                                    },
                                  ),

                                  const SizedBox(height: 18),

                                  // رقم الهاتف
                                  _buildFieldLabel(
                                    'رقم الهاتف المحمول',
                                    Icons.phone_android_rounded,
                                  ),
                                  const SizedBox(height: 8),
                                  AuthTextField(
                                    controller: _phoneController,
                                    hintText: '7X XXX XXXX',
                                    keyboardType: TextInputType.phone,
                                    textDirection: TextDirection.ltr,
                                    errorText: _phoneError,
                                    prefixWidget: CountryCodePickerButton(
                                      selectedCountry: _selectedCountry,
                                      onSelected: (country) => setState(
                                        () => _selectedCountry = country,
                                      ),
                                    ),
                                    onChanged: (_) {
                                      if (_phoneError != null)
                                        setState(() => _phoneError = null);
                                    },
                                  ),

                                  const SizedBox(height: 18),

                                  // كلمة السر
                                  _buildFieldLabel(
                                    'كلمة السر',
                                    Icons.lock_outline_rounded,
                                  ),
                                  const SizedBox(height: 8),
                                  AuthTextField(
                                    controller: _passwordController,
                                    hintText: '••••••••',
                                    obscureText: _obscurePassword,
                                    errorText: _passwordError,
                                    prefixWidget: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: Icon(
                                        Icons.lock_outline_rounded,
                                        color: AppColors.accentGold.withValues(
                                          alpha: 0.7,
                                        ),
                                        size: 20,
                                      ),
                                    ),
                                    suffixIcon: IconButton(
                                      icon: Icon(
                                        _obscurePassword
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                        color: AppColors.textMuted,
                                        size: 20,
                                      ),
                                      onPressed: () => setState(
                                        () => _obscurePassword =
                                            !_obscurePassword,
                                      ),
                                    ),
                                    onChanged: (_) {
                                      setState(() {});
                                      if (_passwordError != null)
                                        setState(() => _passwordError = null);
                                    },
                                  ),

                                  // مؤشر قوة كلمة السر
                                  if (_passwordController.text.isNotEmpty) ...[
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            child: LinearProgressIndicator(
                                              value: strength,
                                              backgroundColor:
                                                  AppColors.borderLight,
                                              valueColor:
                                                  AlwaysStoppedAnimation(
                                                    _strengthColor(strength),
                                                  ),
                                              minHeight: 5,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Text(
                                          _strengthLabel(strength),
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: _strengthColor(strength),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],

                                  const SizedBox(height: 18),

                                  // تأكيد كلمة السر
                                  _buildFieldLabel(
                                    'تأكيد كلمة السر',
                                    Icons.lock_outline_rounded,
                                  ),
                                  const SizedBox(height: 8),
                                  AuthTextField(
                                    controller: _confirmPasswordController,
                                    hintText: '••••••••',
                                    obscureText: _obscureConfirmPassword,
                                    errorText: _confirmPasswordError,
                                    prefixWidget: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: Icon(
                                        Icons.lock_outline_rounded,
                                        color: AppColors.accentGold.withValues(
                                          alpha: 0.7,
                                        ),
                                        size: 20,
                                      ),
                                    ),
                                    suffixIcon: IconButton(
                                      icon: Icon(
                                        _obscureConfirmPassword
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                        color: AppColors.textMuted,
                                        size: 20,
                                      ),
                                      onPressed: () => setState(
                                        () => _obscureConfirmPassword =
                                            !_obscureConfirmPassword,
                                      ),
                                    ),
                                    onChanged: (_) {
                                      if (_confirmPasswordError != null)
                                        setState(
                                          () => _confirmPasswordError = null,
                                        );
                                    },
                                  ),

                                  const SizedBox(height: 16),

                                  // الموافقة على الشروط
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: Checkbox(
                                          value: _agreedToTerms,
                                          activeColor: AppColors.primary,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              5,
                                            ),
                                          ),
                                          onChanged: (val) => setState(
                                            () => _agreedToTerms = val ?? false,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'أوافق على شروط الاستخدام وسياسة الخصوصية المالية',
                                          style: AppTypography.bodySmall(
                                            color: AppColors.textSecondary,
                                          ).copyWith(fontSize: 11.5),
                                        ),
                                      ),
                                    ],
                                  ),

                                  if (authState.errorMessage != null) ...[
                                    const SizedBox(height: 12),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppColors.errorLight,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: AppColors.error.withValues(
                                            alpha: 0.2,
                                          ),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.warning_amber_rounded,
                                            size: 18,
                                            color: AppColors.error,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              authState.errorMessage!,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: AppColors.error,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],

                                  const SizedBox(height: 22),

                                  // زر إنشاء الحساب
                                  CustomButton(
                                    text: 'إنشاء الحساب ومتابعة التحقق',
                                    icon: Icons.arrow_forward_rounded,
                                    isLoading: isLoading,
                                    onPressed: _handleRegister,
                                  ),
                                ],
                              ),
                            )
                            .animate()
                            .fadeIn(delay: 200.ms, duration: 500.ms)
                            .slideY(begin: 0.12, end: 0),

                        const SizedBox(height: 24),

                        // رابط تسجيل الدخول
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'لديك حساب بالفعل؟',
                              style: AppTypography.bodyMedium(
                                color: AppColors.textSecondary,
                              ),
                            ),
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () => Navigator.pop(context),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.secondary.withValues(
                                    alpha: 0.08,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  'تسجيل الدخول',
                                  style:
                                      AppTypography.titleSmall(
                                        color: AppColors.secondary,
                                      ).copyWith(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 13,
                                      ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep(int number, String label, bool isActive) {
    return Column(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive
                ? AppColors.accentGold
                : Colors.white.withValues(alpha: 0.15),
            border: Border.all(
              color: isActive
                  ? AppColors.accentGold
                  : Colors.white.withValues(alpha: 0.3),
              width: 2,
            ),
          ),
          child: Center(
            child: Text(
              '$number',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: isActive ? AppColors.primaryDark : Colors.white70,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            color: isActive ? Colors.white : Colors.white54,
          ),
        ),
      ],
    );
  }

  Widget _buildTypeCard({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool isSelected,
    required VoidCallback onTap,
    required Color color,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.08)
              : AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? color : AppColors.borderLight,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isSelected
                    ? color.withValues(alpha: 0.12)
                    : AppColors.borderSubtle,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: isSelected ? color : AppColors.textMuted,
                size: 24,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: isSelected ? color : AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFieldLabel(String label, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.secondary),
        const SizedBox(width: 6),
        Text(
          label,
          style: AppTypography.titleSmall(
            color: AppColors.textPrimary,
          ).copyWith(fontWeight: FontWeight.w700, fontSize: 13),
        ),
      ],
    );
  }
}

/// قصاصة المنحنى العلوي
class _TopCurveClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    path.lineTo(0, size.height - 50);
    path.quadraticBezierTo(
      size.width * 0.5,
      size.height + 15,
      size.width,
      size.height - 50,
    );
    path.lineTo(size.width, 0);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
