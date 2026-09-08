import 'package:muthbat/shared/widgets/top_notice.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/brand_logo.dart';
import '../../../../shared/widgets/custom_button.dart';
import '../controllers/auth_controller.dart';
import '../widgets/pin_code_fields.dart';
import '../validators/auth_validators.dart';

/// واجهة التحقق الاحترافية من رمز واتساب (WhatsApp OTP Verification)
class OtpVerificationScreen extends ConsumerStatefulWidget {
  const OtpVerificationScreen({super.key});

  @override
  ConsumerState<OtpVerificationScreen> createState() =>
      _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends ConsumerState<OtpVerificationScreen> {
  final GlobalKey<PinCodeFieldsState> _pinKey = GlobalKey<PinCodeFieldsState>();
  String _enteredCode = '';
  int _ttlSeconds = 300; // 5 دقائق صلاحية الرمز
  int _cooldownSeconds = 60; // 60 ثانية قبل إعادة الإرسال
  Timer? _timer;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _startTimers();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimers() {
    _timer?.cancel();
    setState(() {
      _ttlSeconds = 300;
      _cooldownSeconds = 60;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          if (_ttlSeconds > 0) _ttlSeconds--;
          if (_cooldownSeconds > 0) _cooldownSeconds--;
        });
      }
    });
  }

  void _handleVerify([String? codeToVerify]) async {
    if (_isSubmitting) return;

    final code = AuthValidators.normalizeOtp(
      (codeToVerify ?? _enteredCode).trim(),
    );
    if (AuthValidators.otpError(code) != null) {
      TopNotice.of(context).showSnackBar(
        const SnackBar(
          content: Text('يرجى إدخال رمز التحقق المكون من 6 أرقام كاملاً'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }
    if (_ttlSeconds <= 0) {
      TopNotice.of(context).showSnackBar(
        const SnackBar(
          content: Text('انتهت صلاحية الرمز. اطلب رمزًا جديدًا للمتابعة.'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    // التحقق خادمي 100% عبر Supabase Phone Auth (Twilio Verify) —
    // المسار يُحدَّد من سياق الشاشة: تسجيل جديد أم استرداد حساب.
    final controller = ref.read(authControllerProvider.notifier);
    final pendingAction = ref.read(authControllerProvider).pendingAction;
    if (pendingAction == null) {
      TopNotice.of(context).showSnackBar(
        const SnackBar(
          content: Text('انتهت جلسة التحقق. ابدأ الطلب من جديد.'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    final success = pendingAction == AuthPendingAction.recovery
        ? await controller.verifyRecoveryOtp(code)
        : await controller.verifySignupOtp(code);
    if (mounted) setState(() => _isSubmitting = false);

    if (success && mounted) {
      if (pendingAction == AuthPendingAction.recovery) {
        // جلسة الاسترداد نشطة — الخطوة التالية: تعيين كلمة سر جديدة.
        Navigator.pushNamed(context, '/reset-password');
      } else {
        _showSuccessDialog();
      }
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          content: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: AppColors.successLight,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.success.withValues(alpha: 0.2),
                        blurRadius: 20,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.success,
                    size: 52,
                  ),
                ).animate().scale(duration: 500.ms, curve: Curves.easeOutBack),
                const SizedBox(height: 20),
                Text(
                  'تم التحقق وتفعيل الحساب!',
                  textAlign: TextAlign.center,
                  style: AppTypography.titleLarge(
                    color: AppColors.primary,
                  ).copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  'تم تأكيد رقم هاتفك بنجاح عبر واتساب. حسابك المالي المشفر جاهز للاستخدام الآن.',
                  textAlign: TextAlign.center,
                  style: AppTypography.bodyMedium(
                    color: AppColors.textSecondary,
                  ).copyWith(height: 1.45),
                ),
                const SizedBox(height: 24),
                CustomButton(
                  text: 'بدء الاستخدام والدخول للرئيسية',
                  icon: Icons.arrow_forward_rounded,
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final userType = ref.read(authControllerProvider).userType;
                    if (userType == 'customer') {
                      Navigator.pushNamedAndRemoveUntil(
                        context,
                        AppRoutes.customerHome,
                        (r) => false,
                      );
                    } else {
                      final authState = ref.read(authControllerProvider);
                      if (mounted) {
                        if (authState.requiresBusinessSetup) {
                          Navigator.pushNamedAndRemoveUntil(
                            context,
                            AppRoutes.businessSetup,
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
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatTtl(int seconds) {
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final isLoading = authState.status == AuthStatus.loading;
    final phone = authState.phoneNumber ?? '+967 7X XXX XXXX';

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
              // 1. الشعار والترويسة
              const Center(child: BrandLogo.primary(width: 180)),

              const SizedBox(height: 20),

              // 2. بطاقة إشعار الواتساب الفاخرة (WhatsApp Verified Banner)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFE7F8EE),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: const Color(0xFF25D366).withValues(alpha: 0.4),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF25D366).withValues(alpha: 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: Color(0xFF25D366),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.chat_bubble_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'تم إرسال رمز التحقق عبر واتساب',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F5132),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'تحقق من رسائل تطبيق واتساب على رقمك',
                            style: TextStyle(
                              fontSize: 11,
                              color: const Color(
                                0xFF0F5132,
                              ).withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1, end: 0),

              const SizedBox(height: 18),

              // 3. عرض رقم الهاتف مع زر التعديل
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.borderLight),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        phone,
                        textDirection: TextDirection.ltr,
                        style: AppTypography.financialAmount(
                          fontSize: 16,
                          color: AppColors.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 10),
                      InkWell(
                        onTap: () => Navigator.pop(context),
                        borderRadius: BorderRadius.circular(12),
                        child: const Padding(
                          padding: EdgeInsets.all(2.0),
                          child: Icon(
                            Icons.edit_note_rounded,
                            size: 20,
                            color: AppColors.secondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // 4. بطاقة مربعات إدخال رمز التحقق
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: AppColors.borderLight, width: 1.2),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.05),
                      blurRadius: 18,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Text(
                      'أدخل الرمز السداسي',
                      style: AppTypography.titleSmall(
                        color: AppColors.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 14),

                    // حقول إدخال الـ 6 أرقام
                    PinCodeFields(
                      key: _pinKey,
                      length: 6,
                      onChanged: (val) => setState(() => _enteredCode = val),
                      onCompleted: (val) {
                        setState(() => _enteredCode = val);
                        _handleVerify(val);
                      },
                    ),

                    // صلاحية الرمز التنازلية
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          size: 15,
                          color: _ttlSeconds > 60
                              ? AppColors.textSecondary
                              : AppColors.error,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'صلاحية الرمز: ${_formatTtl(_ttlSeconds)}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: _ttlSeconds > 60
                                ? AppColors.textSecondary
                                : AppColors.error,
                          ),
                        ),
                      ],
                    ),

                    if (authState.errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
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

                    // زر التأكيد والمتابعة
                    CustomButton(
                      text: 'تأكيد الرمز وتفعيل الحساب',
                      icon: Icons.check_circle_outline_rounded,
                      isLoading: isLoading,
                      onPressed: _isSubmitting ? null : () => _handleVerify(),
                    ),
                  ],
                ),
              ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.15, end: 0),

              const SizedBox(height: 20),

              // 5. زر إعادة الإرسال مع مؤقت الـ 60 ثانية Cooldown
              Center(
                child: _cooldownSeconds > 0
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.hourglass_empty_rounded,
                            size: 16,
                            color: AppColors.textSecondary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'يمكنك طلب رمز جديد بعد $_cooldownSeconds ثانية',
                            style: AppTypography.bodySmall(
                              color: AppColors.textSecondary,
                            ).copyWith(fontWeight: FontWeight.w600),
                          ),
                        ],
                      )
                    : TextButton.icon(
                        onPressed: () async {
                          final messenger = TopNotice.of(context);
                          final success = await ref
                              .read(authControllerProvider.notifier)
                              .resendOtp();
                          if (!success) {
                            if (mounted) {
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'تعذر إعادة إرسال الرمز. حاول لاحقًا.',
                                  ),
                                  backgroundColor: AppColors.error,
                                ),
                              );
                            }
                            return;
                          }
                          _startTimers();
                          _pinKey.currentState?.clear();
                          if (mounted) setState(() => _enteredCode = '');
                          if (mounted) {
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'تم إرسال رمز جديد إلى واتساب بنجاح 📲',
                                ),
                                backgroundColor: Color(0xFF25D366),
                              ),
                            );
                          }
                        },
                        icon: const Icon(
                          Icons.refresh_rounded,
                          size: 18,
                          color: Color(0xFF128C7E),
                        ),
                        label: const Text(
                          'إعادة إرسال رمز التحقق عبر واتساب',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            color: Color(0xFF128C7E),
                          ),
                        ),
                      ),
              ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
