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
  String? _selectedResolution;
  final _noteController = TextEditingController();
  final _correctedAmountController = TextEditingController();
  bool _isSubmitting = false;
  bool _isReviewing = false;

  String get _currency =>
      widget.dispute.currencyCode ??
      ref.read(merchantControllerProvider).currency;

  Money? get _correctedMoney {
    final text = _correctedAmountController.text
        .replaceAllMapped(RegExp('[٠-٩۰-۹]'), (match) {
          final code = match[0]!.codeUnitAt(0);
          return String.fromCharCode(
            48 + code - (code >= 0x06f0 ? 0x06f0 : 0x0660),
          );
        })
        .replaceAll('٫', '.')
        .replaceAll('٬', '');
    return Money.tryParse(text);
  }

  String _amount(num value) =>
      '${NumberFormat('#,##0.####').format(value)} $_currency';

  String get _decisionLabel => switch (_selectedResolution) {
    'partially_accepted' => 'قبول الاعتراض وتصحيح المبلغ',
    'accepted' => 'قبول الاعتراض وإلغاء العملية',
    _ => 'رفض الاعتراض والإبقاء على العملية',
  };

  String _outcome(double? corrected) => switch (_selectedResolution) {
    'partially_accepted' =>
      corrected == null
          ? 'أدخل المبلغ الصحيح لعرض نتيجة التصحيح.'
          : 'المبلغ بعد التصحيح: ${_amount(corrected)}',
    'accepted' => 'سيُلغى أثر هذه العملية بالكامل على الرصيد.',
    _ =>
      'ستبقى العملية بمبلغ ${_amount(widget.dispute.entryAmount!)} دون تغيير.',
  };

  @override
  void dispose() {
    _noteController.dispose();
    _correctedAmountController.dispose();
    super.dispose();
  }

  void _handleResolve() async {
    if (_isSubmitting || _isReviewing || _selectedResolution == null) return;
    if (!_formKey.currentState!.validate()) return;
    final resolution = _selectedResolution!;
    final correctedAmount = resolution == 'partially_accepted'
        ? _correctedMoney!.toDouble()
        : null;
    final note = _noteController.text.trim();
    setState(() => _isReviewing = true);
    FocusScope.of(context).unfocus();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('مراجعة قرار الاعتراض'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_decisionLabel),
              const SizedBox(height: 12),
              Text(
                'مبلغ العملية الأصلي: ${_amount(widget.dispute.entryAmount!)}',
              ),
              const SizedBox(height: 8),
              Text(_outcome(correctedAmount)),
              const SizedBox(height: 12),
              Text('سبب القرار: $note'),
              const SizedBox(height: 12),
              const Text(
                'سيُرسل القرار للمزامنة. يتغير الرصيد بعد تأكيد الخادم، ويظل سجل العملية الأصلية محفوظًا.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('العودة للتعديل'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('تأكيد وحفظ القرار'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() {
      _isReviewing = false;
      _isSubmitting = confirmed == true;
    });
    if (confirmed != true) {
      return;
    }

    final success = await ref
        .read(merchantControllerProvider.notifier)
        .resolveDispute(
          disputeId: widget.dispute.id,
          resolution: resolution,
          note: note,
          correctedAmount: correctedAmount,
        );

    if (mounted) {
      setState(() => _isSubmitting = false);
      if (success) {
        Navigator.pop(context, true);
        TopNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'حُفظ القرار على الجهاز وسيُرسل تلقائيًا. تظهر النتيجة المالية النهائية بعد اعتماد الخادم.',
            ),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        TopNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ref.read(merchantControllerProvider).lastError ??
                  'تعذر حفظ القرار. حاول مجددًا.',
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
    final origAmount = widget.dispute.entryAmount ?? 0.0;
    final amountAvailable = origAmount.isFinite && origAmount > 0;

    return Container(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: const BoxDecoration(
        color: AppColors.white,
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
                'معالجة الاعتراض',
                style: AppTypography.titleMedium(color: AppColors.textPrimary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                amountAvailable
                    ? 'مبلغ العملية الأصلي: ${_amount(origAmount)}'
                    : 'تعذر قراءة مبلغ العملية. حدّث بيانات الاعتراض قبل اتخاذ القرار.',
                style: AppTypography.caption(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              const Text(
                'اختر الإجراء المناسب. قبول الاعتراض لا يعني إلغاء العملية تلقائيًا.',
              ),
              const SizedBox(height: 12),

              // خيارات القرار الثلاثة
              RadioGroup<String>(
                groupValue: _selectedResolution,
                onChanged: (value) {
                  if (value != null && !_isSubmitting) {
                    setState(() => _selectedResolution = value);
                  }
                },
                child: Column(
                  children: [
                    _buildResolutionOption(
                      value: 'accepted',
                      title: 'قبول الاعتراض وإلغاء العملية',
                      subtitle: 'إلغاء أثر العملية بالكامل مع الاحتفاظ بسجلها.',
                      icon: Icons.check_circle_outline_rounded,
                      color: AppColors.success,
                    ),
                    const SizedBox(height: 8),
                    _buildResolutionOption(
                      value: 'partially_accepted',
                      title: 'قبول الاعتراض وتصحيح المبلغ',
                      subtitle:
                          'إدخال المبلغ الصحيح للعملية بدل المبلغ المسجل.',
                      icon: Icons.published_with_changes_rounded,
                      color: AppColors.accentGoldDark,
                    ),
                    const SizedBox(height: 8),
                    _buildResolutionOption(
                      value: 'rejected',
                      title: 'رفض الاعتراض والإبقاء على العملية',
                      subtitle: 'الإبقاء على القيد كما هو مسجل دون تعديل.',
                      icon: Icons.cancel_outlined,
                      color: AppColors.debtRed,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // حقل المبلغ المصحح (إذا اختار قبول جزئي)
              if (_selectedResolution == 'partially_accepted') ...[
                TextFormField(
                  key: const Key('dispute-corrected-amount'),
                  controller: _correctedAmountController,
                  readOnly: _isSubmitting,
                  onChanged: (_) => setState(() {}),
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
                    labelText: 'المبلغ الصحيح للعملية *',
                    hintText: 'أدخل المبلغ المتفق عليه',
                    suffixText: _currency,
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
                    if (val == null || val.trim().isEmpty) {
                      return 'يرجى إدخال المبلغ المصحح';
                    }
                    final parsed = _correctedMoney?.toDouble();
                    if (parsed == null || parsed <= 0) {
                      return 'المبلغ يجب أن يكون أكبر من 0';
                    }
                    if (origAmount > 0 && parsed >= origAmount) {
                      return 'المبلغ المصحح يجب أن يكون أقل من المبلغ الأصلي ($origAmount)';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
              ],
              if (_selectedResolution != null && amountAvailable) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(_outcome(_correctedMoney?.toDouble())),
                ),
                const SizedBox(height: 16),
              ],

              // حقل ملاحظة القرار
              TextFormField(
                key: const Key('dispute-decision-note'),
                controller: _noteController,
                readOnly: _isSubmitting,
                maxLength: 4000,
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
                  if (val == null || val.trim().isEmpty) {
                    return 'يرجى كتابة ملاحظة توضيحية للقرار';
                  }
                  if (val.trim().length < 3) return 'الملاحظة قصيرة جداً';
                  if (val.trim().length > 4000) return 'الحد الأقصى 4000 حرف';
                  return null;
                },
              ),
              const SizedBox(height: 24),

              // زر التثبيت
              CustomButton(
                key: const Key('dispute-review'),
                text: 'مراجعة القرار',
                isLoading: _isSubmitting,
                variant: _selectedResolution == 'rejected'
                    ? ButtonVariant.primary
                    : ButtonVariant.secondary,
                onPressed: _selectedResolution == null || !amountAvailable
                    ? null
                    : _handleResolve,
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
      onTap: _isSubmitting
          ? null
          : () => setState(() => _selectedResolution = value),
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
            Radio<String>(value: value, activeColor: color),
          ],
        ),
      ),
    );
  }
}
