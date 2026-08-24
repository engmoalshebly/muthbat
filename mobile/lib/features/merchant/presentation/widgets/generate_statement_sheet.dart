import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/custom_button.dart';
import '../../data/models/business_customer_model.dart';
import '../../data/models/statement_model.dart';
import '../controllers/merchant_controller.dart';

/// نافذة إنشاء كشف حساب PDF موثق (Generate Statement Sheet)
class GenerateStatementSheet extends ConsumerStatefulWidget {
  final BusinessCustomerModel customer;

  const GenerateStatementSheet({super.key, required this.customer});

  @override
  ConsumerState<GenerateStatementSheet> createState() =>
      _GenerateStatementSheetState();
}

class _GenerateStatementSheetState
    extends ConsumerState<GenerateStatementSheet> {
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _toDate = DateTime.now();
  bool _isGenerating = false;
  bool _allCurrencies = true;
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

  void _setDatePreset(int days) {
    setState(() {
      _toDate = DateTime.now();
      _fromDate = DateTime.now().subtract(Duration(days: days));
    });
  }

  void _handleGenerate() async {
    setState(() => _isGenerating = true);

    final fromIso = _fromDate.toIso8601String();
    final toIso = _toDate.toIso8601String();

    StatementModel? stmt;
    try {
      final repository = ref.read(merchantRepositoryProvider);
      if (_allCurrencies) {
        final currencies =
            <String>{
                  ...ref.read(merchantControllerProvider).supportedCurrencies,
                  ...widget.customer.currencyBalances.keys,
                }
                .map((code) => code.trim().toUpperCase())
                .where((code) => code.length == 3)
                .toList();
        stmt = await repository.generateAllCurrenciesStatement(
          businessCustomerId: widget.customer.id,
          periodFrom: fromIso,
          periodTo: toIso,
          currencyCodes: currencies,
        );
      } else {
        stmt = await repository.generateStatement(
          businessCustomerId: widget.customer.id,
          periodFrom: fromIso,
          periodTo: toIso,
          currencyCode: _selectedCurrency,
        );
      }
    } catch (_) {
      stmt = null;
    }

    if (mounted) {
      setState(() => _isGenerating = false);
      if (stmt != null) {
        Navigator.pop(context);
        Navigator.pushNamed(
          context,
          AppRoutes.statementPreview,
          arguments: {'statement': stmt, 'customer': widget.customer},
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تعذر إنشاء كشف الحساب. تحقق من الاتصال وحاول مرة أخرى.',
            ),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('yyyy/MM/dd');

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

          // عنوان وشعار التوثيق
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              gradient: AppColors.brandGradient,
              borderRadius: BorderRadius.all(Radius.circular(20)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.picture_as_pdf_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'كشف حساب رسمي موثق',
                        style: AppTypography.titleMedium(color: Colors.white),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'كشف غير قابل للتعديل مشفر بختم SHA-256',
                        style: AppTypography.caption(
                          color: AppColors.accentGold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('كل العملات'),
                selected: _allCurrencies,
                onSelected: (_) => setState(() => _allCurrencies = true),
              ),
              ...<String>{
                    _selectedCurrency,
                    ...ref.read(merchantControllerProvider).supportedCurrencies,
                    ...widget.customer.currencyBalances.keys.map(
                      (code) => code.toUpperCase(),
                    ),
                  }
                  .where((code) => code.length == 3)
                  .map(
                    (code) => ChoiceChip(
                      label: Text(code),
                      selected: !_allCurrencies && _selectedCurrency == code,
                      onSelected: (_) => setState(() {
                        _allCurrencies = false;
                        _selectedCurrency = code;
                      }),
                    ),
                  ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _allCurrencies
                ? 'سيتم إنشاء قسم مستقل لكل عملة داخل ملف واحد.'
                : 'سيتم إنشاء التقرير بعملة $_selectedCurrency فقط.',
            style: AppTypography.caption(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),

          // خيارات الفترة السريعة
          Text(
            'اختيار الفترة الزمنية',
            style: AppTypography.titleSmall(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _buildPresetChip('آخر 30 يوم', 30),
              const SizedBox(width: 8),
              _buildPresetChip('آخر 3 أشهر', 90),
              const SizedBox(width: 8),
              _buildPresetChip('آخر سنة', 365),
            ],
          ),
          const SizedBox(height: 16),

          // من تاريخ
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _fromDate,
                      firstDate: DateTime(2020),
                      lastDate: _toDate,
                    );
                    if (picked != null) setState(() => _fromDate = picked);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundLight,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.borderLight),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'من تاريخ',
                          style: AppTypography.caption(
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(
                              Icons.calendar_today_rounded,
                              size: 16,
                              color: AppColors.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              dateFormat.format(_fromDate),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _toDate,
                      firstDate: _fromDate,
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) setState(() => _toDate = picked);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundLight,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.borderLight),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'إلى تاريخ',
                          style: AppTypography.caption(
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(
                              Icons.event_available_rounded,
                              size: 16,
                              color: AppColors.paymentGreen,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              dateFormat.format(_toDate),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // زر التوليد
          CustomButton(
            text: 'إصدار وتوثيق كشف الحساب',
            isLoading: _isGenerating,
            variant: ButtonVariant.primary,
            onPressed: _handleGenerate,
            icon: Icons.verified_rounded,
          ),
        ],
      ),
    );
  }

  Widget _buildPresetChip(String label, int days) {
    final isSelected = _toDate.difference(_fromDate).inDays == days;

    return Expanded(
      child: GestureDetector(
        onTap: () => _setDatePreset(days),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.primary : AppColors.backgroundLight,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? AppColors.primary : AppColors.borderLight,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: isSelected ? Colors.white : AppColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
