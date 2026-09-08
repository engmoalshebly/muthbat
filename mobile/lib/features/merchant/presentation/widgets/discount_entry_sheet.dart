import 'package:muthbat/shared/widgets/top_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/finance/money.dart';
import '../../../../shared/widgets/custom_button.dart';
import '../../data/models/business_customer_model.dart';
import '../controllers/merchant_controller.dart';

/// نافذة تسجيل خصم لصالح العميل (Discount Entry Sheet)
class DiscountEntrySheet extends ConsumerStatefulWidget {
  final BusinessCustomerModel customer;

  const DiscountEntrySheet({super.key, required this.customer});

  @override
  ConsumerState<DiscountEntrySheet> createState() => _DiscountEntrySheetState();
}

class _DiscountEntrySheetState extends ConsumerState<DiscountEntrySheet> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _descController = TextEditingController();
  bool _isSubmitting = false;
  late String _selectedCurrency;

  @override
  void initState() {
    super.initState();
    final dashboardCurrency = ref
        .read(merchantControllerProvider)
        .currencyCode
        .trim()
        .toUpperCase();
    final customerCurrency = widget.customer.currencyBalances.keys
        .map((code) => code.trim().toUpperCase())
        .firstWhere((code) => code.isNotEmpty, orElse: () => 'YER');
    _selectedCurrency = dashboardCurrency.isNotEmpty
        ? dashboardCurrency
        : customerCurrency;
  }

  @override
  void dispose() {
    _amountController.dispose();
    _descController.dispose();
    super.dispose();
  }

  void _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);

    final money = Money.tryParse(_amountController.text.trim());
    if (money == null) return;
    final amount = money.toDouble();
    final desc = _descController.text.trim();

    final success = await ref
        .read(merchantControllerProvider.notifier)
        .applyDiscount(
          businessCustomerId: widget.customer.id,
          amount: amount,
          description: desc,
          currencyCode: _selectedCurrency,
        );

    if (mounted) {
      setState(() => _isSubmitting = false);
      if (success) {
        Navigator.pop(context, true);
        TopNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تم تسجيل خصم بمبلغ ${NumberFormat('#,##0.##').format(amount)} $_selectedCurrency لصالح العميل',
            ),
            backgroundColor: AppColors.accentGoldDark,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        TopNotice.of(context).showSnackBar(
          const SnackBar(
            content: Text('حدث خطأ أثناء تسجيل الخصم. حاول مرة أخرى.'),
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

              // عنوان الخصم مع أيقونة ذهبية
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: AppColors.goldGradient,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.local_offer_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'تسجيل خصم',
                            style: AppTypography.titleMedium(
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'خصم لصالح ${widget.customer.localDisplayName}',
                            style: AppTypography.caption(
                              color: Colors.white.withValues(alpha: 0.85),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // ملاحظة توضيحية
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppColors.accentGoldContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: AppColors.accentGoldDark,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'الخصم يُنقص رصيد الدين المستحق على العميل',
                        style: AppTypography.caption(
                          color: AppColors.accentGoldDark,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Wrap(
                  spacing: 8,
                  children:
                      <String>{
                            _selectedCurrency,
                            ...ref
                                .read(merchantControllerProvider)
                                .supportedCurrencies,
                            ...widget.customer.currencyBalances.keys.map(
                              (code) => code.toUpperCase(),
                            ),
                          }
                          .where((code) => code.length == 3)
                          .map(
                            (code) => ChoiceChip(
                              label: Text(code),
                              selected: _selectedCurrency == code,
                              onSelected: (_) =>
                                  setState(() => _selectedCurrency = code),
                            ),
                          )
                          .toList(),
                ),
              ),

              // حقل المبلغ
              TextFormField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: AppColors.accentGoldDark,
                ),
                decoration: InputDecoration(
                  labelText: 'مبلغ الخصم *',
                  hintText: '0.00',
                  suffixText: _selectedCurrency,
                  suffixStyle: AppTypography.titleMedium(
                    color: AppColors.accentGoldDark,
                  ),
                  filled: true,
                  fillColor: AppColors.backgroundLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: const BorderSide(color: AppColors.borderLight),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: const BorderSide(
                      color: AppColors.accentGold,
                      width: 2,
                    ),
                  ),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty)
                    return 'يرجى إدخال مبلغ الخصم';
                  final parsedMoney = Money.tryParse(val.trim());
                  final parsed = parsedMoney?.toDouble();
                  if (parsed != null && !parsed.isFinite)
                    return 'المبلغ غير صالح';
                  if (parsed != null && parsed > 9999999999999999.9999)
                    return 'المبلغ أكبر من الحد المسموح';
                  final normalized = val.trim().replaceAll(',', '.');
                  final fraction = normalized.contains('.')
                      ? normalized.split('.').last
                      : '';
                  if (fraction.length > 4)
                    return 'يسمح بأربع منازل عشرية كحد أقصى';
                  if (parsed == null || parsed <= 0)
                    return 'المبلغ يجب أن يكون أكبر من الصفر';
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // حقل الوصف
              TextFormField(
                controller: _descController,
                decoration: InputDecoration(
                  labelText: 'سبب الخصم *',
                  hintText: 'مثال: خصم عميل مميز / خصم تسوية / عرض خاص',
                  prefixIcon: const Icon(
                    Icons.description_outlined,
                    color: AppColors.textSecondary,
                  ),
                  filled: true,
                  fillColor: AppColors.backgroundLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: AppColors.borderLight),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(
                      color: AppColors.accentGold,
                      width: 2,
                    ),
                  ),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty)
                    return 'يرجى كتابة سبب الخصم';
                  return null;
                },
              ),
              const SizedBox(height: 24),

              // زر التثبيت
              CustomButton(
                text: 'تثبيت الخصم',
                isLoading: _isSubmitting,
                variant: ButtonVariant.secondary,
                onPressed: _handleSubmit,
                icon: Icons.local_offer_rounded,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
