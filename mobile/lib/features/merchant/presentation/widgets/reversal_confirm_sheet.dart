import 'package:muthbat/shared/widgets/top_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/custom_button.dart';
import '../../data/models/ledger_entry_model.dart';
import '../controllers/merchant_controller.dart';

/// نافذة تأكيد عكس قيد مالي (Reversal Confirmation Sheet)
class ReversalConfirmSheet extends ConsumerStatefulWidget {
  final LedgerEntryModel entry;
  final String businessCustomerId;

  const ReversalConfirmSheet({
    super.key,
    required this.entry,
    required this.businessCustomerId,
  });

  @override
  ConsumerState<ReversalConfirmSheet> createState() => _ReversalConfirmSheetState();
}

class _ReversalConfirmSheetState extends ConsumerState<ReversalConfirmSheet> {
  final _formKey = GlobalKey<FormState>();
  final _reasonController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _handleReversal() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);

    final success = await ref.read(merchantControllerProvider.notifier).reverseEntry(
      originalEntryId: widget.entry.id,
      businessCustomerId: widget.businessCustomerId,
      originalEntryType: widget.entry.entryType,
      originalDirection: widget.entry.direction,
      originalAmount: widget.entry.amount,
      reason: _reasonController.text.trim(),
    );

    if (mounted) {
      setState(() => _isSubmitting = false);
      if (success) {
        Navigator.pop(context, true);
        TopNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تم عكس القيد بمبلغ ${NumberFormat('#,##0.##').format(widget.entry.amount)} ${ref.read(merchantControllerProvider).currency}',
            ),
            backgroundColor: AppColors.warning,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        TopNotice.of(context).showSnackBar(
          const SnackBar(
            content: Text('حدث خطأ أثناء عكس القيد. حاول مرة أخرى.'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final formatter = NumberFormat('#,##0.##');
    final isDebt = widget.entry.entryType == 'debt';

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

              // أيقونة وعنوان التحذير
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.warningLight,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.undo_rounded,
                        color: AppColors.warning,
                        size: 32,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'عكس قيد مالي',
                      style: AppTypography.titleMedium(color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'هذا الإجراء سينشئ قيداً معاكساً يلغي أثر العملية الأصلية.\nلا يمكن التراجع عن هذا الإجراء.',
                      style: AppTypography.caption(color: AppColors.textSecondary),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // تفاصيل القيد الأصلي
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.backgroundLight,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.borderLight),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'القيد الأصلي المراد عكسه',
                      style: AppTypography.caption(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.entry.description,
                                style: AppTypography.titleSmall(color: AppColors.textPrimary),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                DateFormat('yyyy/MM/dd - hh:mm a').format(
                                  DateTime.parse(widget.entry.occurredAt),
                                ),
                                style: AppTypography.caption(color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: isDebt
                                ? AppColors.debtRed.withValues(alpha: 0.1)
                                : AppColors.paymentGreen.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${isDebt ? '+' : '-'}${formatter.format(widget.entry.amount)} ${ref.read(merchantControllerProvider).currency}',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: isDebt ? AppColors.debtRed : AppColors.paymentGreen,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // حقل سبب العكس
              TextFormField(
                controller: _reasonController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'سبب العكس *',
                  hintText: 'مثال: خطأ في المبلغ / تسجيل مكرر / إلغاء الصفقة',
                  prefixIcon: const Icon(Icons.edit_note_rounded, color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.backgroundLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: AppColors.borderLight),
                  ),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) return 'يرجى كتابة سبب العكس';
                  if (val.trim().length < 3) return 'السبب يجب أن يكون 3 أحرف على الأقل';
                  return null;
                },
              ),
              const SizedBox(height: 24),

              // زر تأكيد العكس
              CustomButton(
                text: 'تأكيد العكس',
                isLoading: _isSubmitting,
                variant: ButtonVariant.primary,
                onPressed: _handleReversal,
                icon: Icons.undo_rounded,
              ),
              const SizedBox(height: 8),

              // زر إلغاء
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'إلغاء',
                  style: AppTypography.bodyMedium(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
