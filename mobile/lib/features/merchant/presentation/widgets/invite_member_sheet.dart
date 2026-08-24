import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/custom_button.dart';
import '../controllers/merchant_controller.dart';

/// نافذة دعوة موظف جديد للانضمام لفريق المحل (Invite Member Sheet)
class InviteMemberSheet extends ConsumerStatefulWidget {
  final String businessId;

  const InviteMemberSheet({
    super.key,
    required this.businessId,
  });

  @override
  ConsumerState<InviteMemberSheet> createState() => _InviteMemberSheetState();
}

class _InviteMemberSheetState extends ConsumerState<InviteMemberSheet> {
  final _formKey = GlobalKey<FormState>();
  final _userIdController = TextEditingController();
  String _selectedRole = 'accountant'; // 'admin', 'accountant', 'collector'
  bool _isSubmitting = false;

  @override
  void dispose() {
    _userIdController.dispose();
    super.dispose();
  }

  void _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);

    final success = await ref.read(merchantRepositoryProvider).inviteMember(
      businessId: widget.businessId,
      targetUserId: _userIdController.text.trim(),
      role: _selectedRole,
    );

    if (mounted) {
      setState(() => _isSubmitting = false);
      if (success) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم إرسال دعوة الانضمام للموظف بنجاح'),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر إرسال الدعوة. تأكد من صحة معرف المستخدم.'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // مقبض النافذة
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.borderMedium,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Text(
                'دعوة موظف جديد',
                style: AppTypography.titleMedium(color: AppColors.textPrimary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'أدخل المعرف الرقمي للمستخدم وحدد صلاحياته في المحل',
                style: AppTypography.caption(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),

              // حقل معرف المستخدم
              TextFormField(
                controller: _userIdController,
                decoration: InputDecoration(
                  labelText: 'المعرف الرقمي للموظف (User ID) *',
                  hintText: 'مثال: e4b2d184-3c87-4b11-b847-7945d820ef69',
                  prefixIcon: const Icon(Icons.person_pin_rounded, color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.backgroundLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: AppColors.borderLight),
                  ),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) return 'يرجى إدخال معرف المستخدم';
                  if (val.trim().length < 8) return 'المعرف غير صالح';
                  return null;
                },
              ),
              const SizedBox(height: 20),

              Text('تحديد الدور والصلاحيات', style: AppTypography.titleSmall(color: AppColors.textPrimary)),
              const SizedBox(height: 10),

              // خيارات الأدوار الثلاثة
              _buildRoleOption(
                role: 'accountant',
                title: 'محاسب مالي',
                subtitle: 'تسجيل القيود والديون، السدادات، الخصومات، وإصدار الكشوفات.',
                icon: Icons.calculate_outlined,
                color: AppColors.primary,
              ),
              const SizedBox(height: 8),
              _buildRoleOption(
                role: 'collector',
                title: 'محصّل ميداني',
                subtitle: 'تسجيل استلام الدفعات المالية ومتابعة حسابات العملاء.',
                icon: Icons.payments_outlined,
                color: AppColors.paymentGreen,
              ),
              const SizedBox(height: 8),
              _buildRoleOption(
                role: 'admin',
                title: 'مدير النظام',
                subtitle: 'صلاحيات كاملة لإدارة الحسابات، التقارير، ودعوة موظفين.',
                icon: Icons.admin_panel_settings_outlined,
                color: AppColors.accentGoldDark,
              ),
              const SizedBox(height: 24),

              // زر الإرسال
              CustomButton(
                text: 'إرسال الدعوة الرسمية',
                isLoading: _isSubmitting,
                variant: ButtonVariant.primary,
                onPressed: _handleSubmit,
                icon: Icons.send_rounded,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoleOption({
    required String role,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    final isSelected = _selectedRole == role;

    return GestureDetector(
      onTap: () => setState(() => _selectedRole = role),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected ? color.withValues(alpha: 0.08) : AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? color : AppColors.borderLight,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: isSelected ? color : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppTypography.caption(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            Radio<String>(
              value: role,
              groupValue: _selectedRole,
              activeColor: color,
              onChanged: (val) {
                if (val != null) setState(() => _selectedRole = val);
              },
            ),
          ],
        ),
      ),
    );
  }
}
