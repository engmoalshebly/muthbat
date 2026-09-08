import 'package:muthbat/shared/widgets/top_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/finance/money.dart';
import '../../../../shared/widgets/custom_button.dart';
import '../../data/models/dispute_model.dart';
import '../controllers/merchant_controller.dart';

/// نافذة معالجة وحل الاعتراض (Resolve Dispute Sheet)
class ResolveDisputeSheet extends ConsumerStatefulWidget {
  final DisputeModel dispute;

  const ResolveDisputeSheet({super.key, required this.dispute});

  @override
  ConsumerState<ResolveDisputeSheet> createState() =>
      _ResolveDisputeSheetState();
}

class _ResolveDisputeSheetState extends ConsumerState<ResolveDisputeSheet> {
  final _formKey = GlobalKey<FormState>();
  String _selectedResolution =
      'accepted'; // 'accepted', 'partially_accepted', 'rejected'
  final _noteController = TextEditingController();
  final _correctedAmountController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _noteController.dispose();
    _correctedAmountController.dispose();
    super.dispose();
  }

  void _handleResolve() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);

    double? correctedAmount;
    if (_selectedResolution == 'partially_accepted') {
      correctedAmount = Money.tryParse(
        _correctedAmountController.text.trim(),
      )?.toDouble();
    }

    final success = await ref
        .read(merchantControllerProvider.notifier)
        .resolveDispute(
          disputeId: widget.dispute.id,
          resolution: _selectedResolution,
          note: _noteController.text.trim(),
          correctedAmount: correctedAmount,
        );

    if (mounted) {
      setState(() => _isSubmitting = false);
      if (success) {
        Navigator.pop(context, true);
        TopNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _selectedResolution == 'accepted'
                  ? 'تم قبول الاعتراض وعكس القيد المالي بنجاح'
                  : (_selectedResolution == 'partially_accepted'
                        ? 'تم قبول الاعتراض جزئياً وتصحيح المبلغ'
                        : 'تم رفض الاعتراض والإبقاء على القيد'),
            ),
            backgroundColor: _selectedResolution == 'rejected'
                ? AppColors.debtRed
                : AppColors.success,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        TopNotice.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'حدث خطأ أثناء معالجة الاعتراض. يرجى المحاولة مرة أخرى.',
            ),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currencyFormatter = NumberFormat('#,##0.##');
    final origAmount = widget.dispute.entryAmount ?? 0.0;

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
                'معالجة واتخاذ قرار بشأن الاعتراض',
                style: AppTypography.titleMedium(color: AppColors.textPrimary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'المبلغ المعترض عليه: ${currencyFormatter.format(origAmount)} ${ref.read(merchantControllerProvider).currency}',
                style: AppTypography.caption(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),

              // خيارات القرار الثلاثة
              _buildResolutionOption(
                value: 'accepted',
                title: 'قبول الاعتراض بالكامل',
                subtitle: 'سيتم عكس القيد الأصلي بالكامل وإلغاؤه من الذمة.',
                icon: Icons.check_circle_outline_rounded,
                color: AppColors.success,
              ),
              const SizedBox(height: 8),
              _buildResolutionOption(
                value: 'partially_accepted',
                title: 'قبول جزئي (تصحيح المبلغ)',
                subtitle: 'عكس القيد وإعادة تسجيله بالمبلغ الصحيح المتفق عليه.',
                icon: Icons.published_with_changes_rounded,
                color: AppColors.accentGoldDark,
              ),
              const SizedBox(height: 8),
              _buildResolutionOption(
                value: 'rejected',
                title: 'رفض الاعتراض',
                subtitle: 'الإبقاء على القيد كما هو مسجل دون تعديل.',
                icon: Icons.cancel_outlined,
                color: AppColors.debtRed,
              ),
              const SizedBox(height: 20),

              // حقل المبلغ المصحح (إذا اختار قبول جزئي)
              if (_selectedResolution == 'partially_accepted') ...[
                TextFormField(
                  controller: _correctedAmountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: AppColors.accentGoldDark,
                  ),
                  decoration: InputDecoration(
                    labelText: 'المبلغ الصحيح المستحق *',
                    hintText: '0.00',
                    suffixText: '${ref.read(merchantControllerProvider).currency}',
                    filled: true,
                    fillColor: AppColors.backgroundLight,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(
                        color: AppColors.borderLight,
                      ),
                    ),
                  ),
                  validator: (val) {
                    if (val == null || val.trim().isEmpty)
                      return 'يرجى إدخال المبلغ المصحح';
                    final parsed = Money.tryParse(val.trim())?.toDouble();
                    if (parsed == null || parsed <= 0)
                      return 'المبلغ يجب أن يكون أكبر من 0';
                    if (origAmount > 0 && parsed >= origAmount) {
                      return 'المبلغ المصحح يجب أن يكون أقل من المبلغ الأصلي ($origAmount)';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
              ],

              // حقل ملاحظة القرار
              TextFormField(
                controller: _noteController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'ملاحظة القرار / سبب الإجراء *',
                  hintText: 'اكتب توضيحاً للعميل عن سبب هذا القرار...',
                  prefixIcon: const Icon(
                    Icons.note_alt_outlined,
                    color: AppColors.textSecondary,
                  ),
                  filled: true,
                  fillColor: AppColors.backgroundLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: AppColors.borderLight),
                  ),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty)
                    return 'يرجى كتابة ملاحظة توضيحية للقرار';
                  if (val.trim().length < 3) return 'الملاحظة قصيرة جداً';
                  return null;
                },
              ),
              const SizedBox(height: 24),

              // زر التثبيت
              CustomButton(
                text: 'تأكيد القرار وإنهاء الاعتراض',
                isLoading: _isSubmitting,
                variant: _selectedResolution == 'rejected'
                    ? ButtonVariant.primary
                    : ButtonVariant.secondary,
                onPressed: _handleResolve,
                icon: Icons.gavel_rounded,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResolutionOption({
    required String value,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    final isSelected = _selectedResolution == value;

    return GestureDetector(
      onTap: () => setState(() => _selectedResolution = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
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
                    style: AppTypography.caption(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Radio<String>(
              value: value,
              groupValue: _selectedResolution,
              activeColor: color,
              onChanged: (val) {
                if (val != null) setState(() => _selectedResolution = val);
              },
            ),
          ],
        ),
      ),
    );
  }
}
