import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/custom_button.dart';
import '../controllers/auth_controller.dart';
import '../widgets/auth_header.dart';
import '../widgets/auth_text_field.dart';
import '../widgets/country_code_picker.dart';
import '../validators/auth_validators.dart';

/// واجهة استعادة الحساب وإعادة تعيين كلمة السر
class AccountRecoveryScreen extends ConsumerStatefulWidget {
  const AccountRecoveryScreen({super.key});

  @override
  ConsumerState<AccountRecoveryScreen> createState() =>
      _AccountRecoveryScreenState();
}

class _AccountRecoveryScreenState extends ConsumerState<AccountRecoveryScreen> {
  final TextEditingController _phoneController = TextEditingController();
  CountryInfo _selectedCountry = supportedCountries[0];
  String? _phoneError;

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  void _handleRecovery() async {
    final rawPhone = _phoneController.text.trim();
    if (rawPhone.isEmpty || rawPhone.length < 7) {
      setState(() => _phoneError = 'يرجى إدخال رقم الهاتف المسجل بشكل صحيح');
      return;
    }

    final strictPhoneError = AuthValidators.phoneError(
      raw: rawPhone,
      dialCode: _selectedCountry.dialCode,
    );
    if (strictPhoneError != null) {
      setState(() => _phoneError = strictPhoneError);
      return;
    }

    setState(() => _phoneError = null);

    final fullPhone = AuthValidators.normalizePhone(
      raw: rawPhone,
      dialCode: _selectedCountry.dialCode,
    );
    final success = await ref
        .read(authControllerProvider.notifier)
        .sendRecoveryOtp(phone: fullPhone);

    if (success && mounted) {
      Navigator.pushNamed(context, AppRoutes.otp);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final isLoading = authState.status == AuthStatus.loading;

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: AppColors.primary,
          ),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. الترويسة والشعار
              const AuthHeader(
                title: 'استعادة الوصول للحساب',
                subtitle:
                    'أدخل رقم هاتفك المسجل لنرسل لك رمز تحقق آمن عبر واتساب لاستعادة سجلاتك المالية',
                showLogo: true,
              ),

              const SizedBox(height: 20),

              // 2. بطاقة إشعار واتساب للأمان
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFE7F8EE),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: const Color(0xFF25D366).withValues(alpha: 0.4),
                    width: 1.2,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(
                        color: Color(0xFF25D366),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.chat_bubble_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'استعادة الحساب عبر واتساب',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F5132),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'سنرسل رمز تحقق سداسي (OTP) إلى واتساب على رقمك المعتمد.',
                            style: TextStyle(
                              fontSize: 11,
                              color: const Color(
                                0xFF0F5132,
                              ).withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ).animate().fadeIn(duration: 400.ms),

              const SizedBox(height: 20),

              // 3. بطاقة إدخال رقم الهاتف
              Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: AppColors.borderLight,
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.05),
                          blurRadius: 18,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'رقم الهاتف المحمول المسجل',
                          style: AppTypography.titleSmall(
                            color: AppColors.textPrimary,
                          ).copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        AuthTextField(
                          controller: _phoneController,
                          hintText: '7X XXX XXXX',
                          keyboardType: TextInputType.phone,
                          textDirection: TextDirection.ltr,
                          errorText: _phoneError,
                          prefixWidget: CountryCodePickerButton(
                            selectedCountry: _selectedCountry,
                            onSelected: (country) =>
                                setState(() => _selectedCountry = country),
                          ),
                          onChanged: (_) {
                            if (_phoneError != null)
                              setState(() => _phoneError = null);
                          },
                        ),

                        if (authState.errorMessage != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.errorLight,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.error_outline_rounded,
                                  size: 16,
                                  color: AppColors.error,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    authState.errorMessage!,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.error,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 22),

                        CustomButton(
                          text: 'إرسال رمز التحقق إلى واتساب',
                          icon: Icons.send_rounded,
                          isLoading: isLoading,
                          onPressed: _handleRecovery,
                        ),
                      ],
                    ),
                  )
                  .animate()
                  .fadeIn(delay: 200.ms, duration: 500.ms)
                  .slideY(begin: 0.15, end: 0),

              const SizedBox(height: 24),

              // العودة لتسجيل الدخول
              Center(
                child: TextButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    size: 18,
                    color: AppColors.secondary,
                  ),
                  label: Text(
                    'العودة إلى تسجيل الدخول',
                    style: AppTypography.titleSmall(
                      color: AppColors.secondary,
                    ).copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
