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
import '../validators/auth_validators.dart';

/// شاشة تعيين كلمة سر جديدة بعد نجاح تحقق رمز الاسترداد (خطة 04 §3.3).
/// تُفتح بعد verifyRecoveryOtp الناجح حيث تكون جلسة Supabase نشطة.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  String? _passwordError;
  String? _confirmPasswordError;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _handleReset() async {
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    bool hasError = false;

    if (password.isEmpty) {
      setState(() => _passwordError = 'يرجى إدخال كلمة السر الجديدة');
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

    if (hasError) return;

    final strictPasswordError = AuthValidators.passwordError(password);
    if (strictPasswordError != null) {
      setState(() => _passwordError = strictPasswordError);
      return;
    }

    setState(() {
      _passwordError = null;
      _confirmPasswordError = null;
    });

    final success = await ref
        .read(authControllerProvider.notifier)
        .completePasswordReset(newPassword: password);

    if (success && mounted) {
      final userType = ref.read(authControllerProvider).userType;
      if (userType == 'customer') {
        Navigator.pushNamedAndRemoveUntil(
          context,
          AppRoutes.customerHome,
          (r) => false,
        );
      } else {
        Navigator.pushNamedAndRemoveUntil(
          context,
          AppRoutes.merchantHome,
          (r) => false,
        );
      }
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
          icon: const Icon(Icons.arrow_forward_rounded, color: AppColors.textPrimary),
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
                title: 'كلمة سر جديدة',
                subtitle:
                    'تم تأكيد هويتك بنجاح. عيّن كلمة سر جديدة قوية لحماية سجلاتك المالية',
                showLogo: true,
              ),

              const SizedBox(height: 20),

              // 2. بطاقة كلمة السر الجديدة
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
                          'كلمة السر الجديدة',
                          style: AppTypography.titleSmall(
                            color: AppColors.textPrimary,
                          ).copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        AuthTextField(
                          controller: _passwordController,
                          hintText: '••••••••',
                          obscureText: _obscurePassword,
                          errorText: _passwordError,
                          prefixWidget: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
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
                              () => _obscurePassword = !_obscurePassword,
                            ),
                          ),
                          onChanged: (_) {
                            if (_passwordError != null)
                              setState(() => _passwordError = null);
                          },
                        ),

                        const SizedBox(height: 18),

                        Text(
                          'تأكيد كلمة السر',
                          style: AppTypography.titleSmall(
                            color: AppColors.textPrimary,
                          ).copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        AuthTextField(
                          controller: _confirmPasswordController,
                          hintText: '••••••••',
                          obscureText: _obscureConfirmPassword,
                          errorText: _confirmPasswordError,
                          prefixWidget: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
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
                              setState(() => _confirmPasswordError = null);
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
                          text: 'حفظ كلمة السر والدخول',
                          icon: Icons.check_circle_outline_rounded,
                          isLoading: isLoading,
                          onPressed: _handleReset,
                        ),
                      ],
                    ),
                  )
                  .animate()
                  .fadeIn(delay: 200.ms, duration: 500.ms)
                  .slideY(begin: 0.15, end: 0),
            ],
          ),
        ),
      ),
    );
  }
}
