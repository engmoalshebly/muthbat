import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../shared/widgets/brand_logo.dart';
import '../../../../shared/widgets/custom_button.dart';
import '../controllers/auth_controller.dart';
import '../widgets/auth_text_field.dart';
import '../widgets/country_code_picker.dart';
import '../validators/auth_validators.dart';
import '../customer_entry_mode.dart';

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
        .loginWithPassword(phone: fullPhone, password: password);

    if (success && mounted) {
      final authState = ref.read(authControllerProvider);
      if (authState.userId != null) {
        await CustomerEntryMode.remember(authState.userId!, _customerMode);
      }
      if (!mounted) return;
      if (!_customerMode && authState.userType == 'merchant') {
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
    final authState = ref.watch(authControllerProvider);
    final isLoading = authState.status == AuthStatus.loading;
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: Stack(
        children: [
          // === الخلفية المتدرجة العلوية مع القوس السفلي ===
          ClipPath(
            clipper: _TopCurveClipper(),
            child: Container(
              height: screenHeight * 0.42,
              decoration: const BoxDecoration(
                gradient: AppColors.brandGradient,
              ),
              child: Stack(
                children: [
                  // نمط زخرفي خفيف
                  Positioned(
                    top: -40,
                    right: -60,
                    child: Container(
                      width: 200,
                      height: 200,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.04),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 60,
                    left: -30,
                    child: Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.03),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // === المحتوى القابل للتمرير ===
          SafeArea(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  // --- منطقة الشعار والترحيب ---
                  SizedBox(height: screenHeight * 0.06),
                  const BrandLogo.primary(width: 180)
                      .animate()
                      .fadeIn(duration: 600.ms)
                      .scale(
                        begin: const Offset(0.8, 0.8),
                        end: const Offset(1, 1),
                        duration: 500.ms,
                      ),
                  const SizedBox(height: 12),
                  Text(
                    'مرحباً بك في مُثبَت',
                    style: AppTypography.displayMedium(
                      color: Colors.white,
                    ).copyWith(fontWeight: FontWeight.w800, fontSize: 24),
                  ).animate().fadeIn(delay: 200.ms, duration: 400.ms),
                  const SizedBox(height: 6),
                  Text(
                    _customerMode
                        ? 'حساباتك ومديونيتك لدى البقالات، في مكان واحد'
                        : 'دخول التاجر لإدارة نشاطه التجاري',
                    style: AppTypography.bodyMedium(color: Colors.white70),
                  ).animate().fadeIn(delay: 300.ms, duration: 400.ms),

                  SizedBox(height: screenHeight * 0.05),

                  // --- بطاقة تسجيل الدخول الزجاجية ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child:
                        Container(
                              padding: const EdgeInsets.fromLTRB(
                                22,
                                28,
                                22,
                                22,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(28),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.primary.withValues(
                                      alpha: 0.10,
                                    ),
                                    blurRadius: 32,
                                    offset: const Offset(0, 12),
                                  ),
                                  BoxShadow(
                                    color: AppColors.primary.withValues(
                                      alpha: 0.04,
                                    ),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SegmentedButton<bool>(
                                    segments: const [
                                      ButtonSegment(
                                        value: true,
                                        label: Text('زبون'),
                                        icon: Icon(Icons.person_outline),
                                      ),
                                      ButtonSegment(
                                        value: false,
                                        label: Text('تاجر'),
                                        icon: Icon(Icons.storefront_outlined),
                                      ),
                                    ],
                                    selected: {_customerMode},
                                    onSelectionChanged: isLoading
                                        ? null
                                        : (value) => setState(
                                            () => _customerMode = value.single,
                                          ),
                                  ),
                                  const SizedBox(height: 16),
                                  // عنوان البطاقة
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: AppColors.accentGold
                                              .withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.login_rounded,
                                          color: AppColors.accentGold,
                                          size: 20,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        'تسجيل الدخول',
                                        style: AppTypography.titleLarge(
                                          color: AppColors.textPrimary,
                                        ).copyWith(fontWeight: FontWeight.w800),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 24),

                                  // حقل رقم الهاتف
                                  Text(
                                    'رقم الهاتف المحمول',
                                    style:
                                        AppTypography.titleSmall(
                                          color: AppColors.textPrimary,
                                        ).copyWith(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
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

                                  // حقل كلمة السر
                                  Text(
                                    'كلمة السر',
                                    style:
                                        AppTypography.titleSmall(
                                          color: AppColors.textPrimary,
                                        ).copyWith(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
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
                                      if (_passwordError != null)
                                        setState(() => _passwordError = null);
                                    },
                                  ),

                                  const SizedBox(height: 8),

                                  // رابط نسيت كلمة السر
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton(
                                      onPressed: () => Navigator.pushNamed(
                                        context,
                                        AppRoutes.recovery,
                                      ),
                                      style: TextButton.styleFrom(
                                        padding: EdgeInsets.zero,
                                        minimumSize: const Size(0, 30),
                                      ),
                                      child: Text(
                                        'نسيت كلمة السر؟',
                                        style:
                                            AppTypography.bodySmall(
                                              color: AppColors.secondary,
                                            ).copyWith(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 12,
                                            ),
                                      ),
                                    ),
                                  ),

                                  // رسالة الخطأ
                                  if (authState.errorMessage != null) ...[
                                    const SizedBox(height: 6),
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

                                  // زر تسجيل الدخول الفاخر
                                  CustomButton(
                                    text: 'تسجيل الدخول',
                                    icon: Icons.arrow_forward_rounded,
                                    isLoading: isLoading,
                                    onPressed: _handleLogin,
                                  ),
                                ],
                              ),
                            )
                            .animate()
                            .fadeIn(delay: 300.ms, duration: 500.ms)
                            .slideY(begin: 0.15, end: 0),
                  ),

                  const SizedBox(height: 28),

                  // --- خيار إنشاء حساب جديد ---
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'ليس لديك حساب بعد؟',
                        style: AppTypography.bodyMedium(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () => Navigator.pushNamed(
                          context,
                          AppRoutes.register,
                          arguments: _customerMode ? 'customer' : 'merchant',
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.secondary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'إنشاء حساب جديد',
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
                  ).animate().fadeIn(delay: 500.ms, duration: 400.ms),

                  const SizedBox(height: 28),

                  // --- شارة الأمان ---
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: AppColors.success.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.verified_user_outlined,
                          size: 14,
                          color: AppColors.success,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        AppConstants.securityBadgeText,
                        style: AppTypography.bodySmall(
                          color: AppColors.textMuted,
                        ).copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// قصاصة المنحنى العلوي الفاخر
class _TopCurveClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    path.lineTo(0, size.height - 60);
    path.quadraticBezierTo(
      size.width * 0.5,
      size.height + 20,
      size.width,
      size.height - 60,
    );
    path.lineTo(size.width, 0);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
