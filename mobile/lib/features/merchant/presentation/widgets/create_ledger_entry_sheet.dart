import 'package:muthbat/shared/widgets/top_notice.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/finance/currency_info.dart';
import '../../../../core/finance/money.dart';
import '../controllers/merchant_controller.dart';
import '../../data/models/business_customer_model.dart';
import 'attachment_picker_widget.dart';

/// شاشة تسجيل العمليات المالية الاحترافية (تعدد العملات + تصنيف الأغراض وطرق السداد)
class CreateLedgerEntrySheet extends ConsumerStatefulWidget {
  final BusinessCustomerModel customer;
  final String initialType; // 'debt' or 'payment'

  const CreateLedgerEntrySheet({
    super.key,
    required this.customer,
    this.initialType = 'debt',
  });

  @override
  ConsumerState<CreateLedgerEntrySheet> createState() =>
      _CreateLedgerEntrySheetState();
}

class _CreateLedgerEntrySheetState
    extends ConsumerState<CreateLedgerEntrySheet> {
  final _formKey = GlobalKey<FormState>();
  late String _entryType; // 'debt' or 'payment'
  late String _selectedCurrency; // مقفلة على عملة المحل في MVP (قرار D3)
  String _selectedCategory =
      'goods'; // 'goods', 'cash', 'service', 'transfer', 'other'
  String _selectedPaymentMethod =
      'cash'; // 'cash', 'bank_transfer', 'cheque', 'offset'

  final _amountController = TextEditingController();
  final _descController = TextEditingController();
  final _refController = TextEditingController();
  final _bankController = TextEditingController();

  DateTime? _dueDate;
  File? _attachedFile;
  bool _isSubmitting = false;

  CurrencyInfo _currencyInfo(String code) => CurrencyCatalog.forCode(
    code,
    ref.read(merchantControllerProvider).currencies,
  );

  @override
  void initState() {
    super.initState();
    _entryType = widget.initialType;
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
    if (_entryType == 'payment') {
      _selectedCategory = 'cash';
      _selectedPaymentMethod = 'cash';
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _descController.dispose();
    _refController.dispose();
    _bankController.dispose();
    super.dispose();
  }

  void _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);

    final money = Money.tryParse(_amountController.text.trim());
    if (money == null) return;
    final amount = money.toDouble();
    final desc = _descController.text.trim();
    final dueDateStr = _dueDate?.toIso8601String().split('T')[0];
    final referenceNumber = _refController.text.trim().isNotEmpty
        ? _refController.text.trim()
        : null;
    final bankName = _bankController.text.trim().isNotEmpty
        ? _bankController.text.trim()
        : null;
    final attachmentPath = _attachedFile?.path;

    final success = await ref
        .read(merchantControllerProvider.notifier)
        .createEntry(
          businessCustomerId: widget.customer.id,
          entryType: _entryType,
          amount: amount,
          currencyCode: _selectedCurrency,
          category: _selectedCategory,
          paymentMethod: _selectedPaymentMethod,
          referenceNumber: referenceNumber,
          bankOrAgentName: bankName,
          attachmentPath: attachmentPath,
          description: desc,
          dueDate: dueDateStr,
        );

    if (mounted) {
      setState(() => _isSubmitting = false);
      if (success) {
        Navigator.pop(context, true);
        final currSymbol = _currencyInfo(_selectedCurrency).symbol;
        final formattedAmount = NumberFormat('#,##0.##', 'ar').format(amount);
        TopNotice.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  _entryType == 'debt'
                      ? Icons.arrow_upward_rounded
                      : Icons.check_circle_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _entryType == 'debt'
                        ? 'تم تسجيل دين جديد: $formattedAmount $currSymbol على ${widget.customer.localDisplayName}'
                        : 'تم تسجيل دفعة مستلمة: $formattedAmount $currSymbol من ${widget.customer.localDisplayName}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            backgroundColor: AppColors.primaryDark,
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDebt = _entryType == 'debt';

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
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
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD1D5DB),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // بطاقة العميل مع تفصيل أرصدة العملات
              _buildCustomerInfoCard(),

              const SizedBox(height: 16),

              // 1. مفتاح التبديل الرئيسي (تسجيل دين / تسجيل سداد)
              _buildTypeSwitcher(),

              const SizedBox(height: 16),

              // 2. محدد العملة المتعدد (Multi-Currency Selector)
              _buildCurrencySelector(),

              const SizedBox(height: 14),

              // 3. حقل إدخال المبلغ
              _buildAmountInput(),

              const SizedBox(height: 14),

              // 4. تصنيف غرض العملية / طريقة الدفع
              if (isDebt)
                _buildDebtCategorySelector()
              else
                _buildPaymentMethodSelector(),

              // حقول التحويل البنكي / الصرافة التفاعلية
              if (!isDebt && _selectedPaymentMethod == 'bank_transfer') ...[
                const SizedBox(height: 12),
                _buildBankTransferFields(),
              ],

              const SizedBox(height: 14),

              // 5. حقل البيان والملاحظات
              TextFormField(
                controller: _descController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: isDebt
                      ? 'بيان الدين / تفاصيل الأصناف أو الفاتورة'
                      : 'ملاحظات وتفاصيل السداد',
                  hintText: isDebt
                      ? 'مثال: مشتريات مواد غذائية فاتورة #104'
                      : 'مثال: دفعة من الحساب نقداً',
                  prefixIcon: const Icon(Icons.description_outlined, size: 20),
                  filled: true,
                  fillColor: const Color(0xFFF9FAFB),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                  ),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'يرجى كتابة بيان مختصر للعملية';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 12),

              // 6. منتقي تاريخ الاستحقاق (اختياري للديون)
              if (isDebt) _buildDueDatePicker(),

              const SizedBox(height: 12),

              // 7. إرفاق صورة الفاتورة / المستند
              AttachmentPickerWidget(
                onFileSelected: (f) => setState(() => _attachedFile = f),
                label: 'إرفاق صورة الفاتورة / سند القبض (اختياري)',
              ),

              const SizedBox(height: 20),

              // 8. زر الحفظ والتوثيق
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _handleSubmit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDebt
                        ? AppColors.debtRed
                        : AppColors.paymentGreen,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          isDebt
                              ? '✓ توثيق قيد الدين (${_currencyInfo(_selectedCurrency).symbol})'
                              : '✓ توثيق استلام الدفعة (${_currencyInfo(_selectedCurrency).symbol})',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// بطاقة ملخص العميل وأرصدته متعددة العملات
  Widget _buildCustomerInfoCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: AppColors.primary,
            radius: 20,
            child: Text(
              widget.customer.localDisplayName.isNotEmpty
                  ? widget.customer.localDisplayName[0]
                  : 'ع',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.customer.localDisplayName,
                  style: AppTypography.titleSmall(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                _buildCustomerMultiCurrencyBalanceText(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomerMultiCurrencyBalanceText() {
    final currencyBals = widget.customer.currencyBalances;
    if (currencyBals.isEmpty) {
      final bal = widget.customer.currentBalance;
      return Text(
        bal == 0
            ? 'الرصيد: خالص (0.00)'
            : (bal > 0
                  ? 'عليه: ${NumberFormat('#,##0').format(bal)} ${ref.read(merchantControllerProvider).currency}'
                  : 'له: ${NumberFormat('#,##0').format(bal.abs())} ${ref.read(merchantControllerProvider).currency}'),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: bal > 0
              ? AppColors.debtRed
              : (bal < 0 ? AppColors.paymentGreen : AppColors.textMuted),
        ),
      );
    }

    final List<String> balanceStrings = [];
    currencyBals.forEach((curr, bal) {
      if (bal != 0) {
        final symbol = _currencyInfo(curr).symbol;
        final prefix = bal > 0 ? 'عليه' : 'له';
        balanceStrings.add(
          '$prefix ${NumberFormat('#,##0.##').format(bal.abs())} $symbol',
        );
      }
    });

    if (balanceStrings.isEmpty) {
      return const Text(
        'الرصيد: خالص بكافة العملات (0)',
        style: TextStyle(fontSize: 11, color: AppColors.textMuted),
      );
    }

    return Text(
      balanceStrings.join(' | '),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Color(0xFF0F766E),
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// مفتاح التبديل بين دين ودفعة
  Widget _buildTypeSwitcher() {
    final isDebt = _entryType == 'debt';

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() {
                _entryType = 'debt';
                _selectedCategory = 'goods';
              }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: isDebt ? AppColors.debtRed : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                  boxShadow: isDebt
                      ? [
                          BoxShadow(
                            color: AppColors.debtRed.withValues(alpha: 0.3),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.add_circle_outline_rounded,
                      size: 16,
                      color: isDebt ? Colors.white : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'تسجيل دَين (+ قيد ذمة)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: isDebt ? Colors.white : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() {
                _entryType = 'payment';
                _selectedCategory = 'cash';
                _selectedPaymentMethod = 'cash';
              }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: !isDebt ? AppColors.paymentGreen : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                  boxShadow: !isDebt
                      ? [
                          BoxShadow(
                            color: AppColors.paymentGreen.withValues(
                              alpha: 0.3,
                            ),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.check_circle_outline_rounded,
                      size: 16,
                      color: !isDebt ? Colors.white : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'تسجيل سداد (✓ قبض دفعة)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: !isDebt ? Colors.white : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// محدد العملة المتعدد
  Widget _buildCurrencySelector() {
    final supported = <String>{
      _selectedCurrency,
      ...ref.read(merchantControllerProvider).supportedCurrencies,
      ...widget.customer.currencyBalances.keys.map(
        (code) => code.toUpperCase(),
      ),
    }.where((code) => code.length == 3).toList();
    final labels = <String, String>{
      for (final code in supported)
        code: '${_currencyInfo(code).symbol} ${_currencyInfo(code).name}',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'العملة المالية للقيد:',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: labels.entries.map((entry) {
            final isSelected = _selectedCurrency == entry.key;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: GestureDetector(
                  onTap: () => setState(() => _selectedCurrency = entry.key),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.primary
                          : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(
                        color: isSelected
                            ? AppColors.primary
                            : const Color(0xFFE2E8F0),
                        width: isSelected ? 1.5 : 1,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        entry.value,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: isSelected
                              ? FontWeight.w800
                              : FontWeight.w600,
                          color: isSelected
                              ? Colors.white
                              : AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  /// حقل إدخال المبلغ المالي
  Widget _buildAmountInput() {
    final currSymbol = _currencyInfo(_selectedCurrency).symbol;

    return TextFormField(
      controller: _amountController,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w900,
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        labelText: 'المبلغ المالي ($currSymbol)',
        hintText: '0.00',
        prefixIcon: const Icon(Icons.attach_money_rounded, size: 22),
        suffixText: currSymbol,
        suffixStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w800,
          color: AppColors.primary,
        ),
        filled: true,
        fillColor: const Color(0xFFF9FAFB),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
      ),
      validator: (val) {
        if (val == null || val.trim().isEmpty) return 'يرجى إدخال المبلغ';
        final parsedMoney = Money.tryParse(val.trim());
        final parsed = parsedMoney?.toDouble();
        if (parsed != null && !parsed.isFinite)
          return 'Ø§Ù„Ù…Ø¨Ù„Øº ØºÙŠØ± ØµØ§Ù„Ø­';
        if (parsed != null && parsed > 9999999999999999.9999)
          return 'Ø§Ù„Ù…Ø¨Ù„Øº Ø£ÙƒØ¨Ø± Ù…Ù† Ø§Ù„Ø­Ø¯ Ø§Ù„Ù…Ø³Ù…ÙˆØ­';
        final normalized = val.trim().replaceAll(',', '.');
        final fraction = normalized.contains('.')
            ? normalized.split('.').last
            : '';
        if (fraction.length > 4)
          return 'ÙŠØ³Ù…Ø­ Ø¨Ø£Ø±Ø¨Ø¹ Ù…Ù†Ø§Ø²Ù„ Ø¹Ø´Ø±ÙŠØ© ÙƒØ­Ø¯ Ø£Ù‚ØµÙ‰';
        if (parsed == null || parsed <= 0)
          return 'يرجى إدخال رقم صحيح أكبر من الصفر';
        return null;
      },
    );
  }

  /// تصنيف غرض الدين
  Widget _buildDebtCategorySelector() {
    final categories = [
      {'key': 'goods', 'label': '📦 بضاعة / مشتريات'},
      {'key': 'cash', 'label': '💵 نقد / قرض مالي'},
      {'key': 'service', 'label': '🛠️ خدمة / عمل'},
      {'key': 'transfer', 'label': '🔄 حوالة عن العميل'},
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'غرض ونوع الدين:',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: categories.map((cat) {
            final isSelected = _selectedCategory == cat['key'];
            return ChoiceChip(
              label: Text(cat['label']!),
              selected: isSelected,
              selectedColor: AppColors.primaryContainer,
              labelStyle: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                color: isSelected ? AppColors.primary : AppColors.textSecondary,
              ),
              onSelected: (_) =>
                  setState(() => _selectedCategory = cat['key']!),
            );
          }).toList(),
        ),
      ],
    );
  }

  /// تصنيف طريقة السداد
  Widget _buildPaymentMethodSelector() {
    final methods = [
      {'key': 'cash', 'label': '💵 نقداً (كاش)'},
      {'key': 'bank_transfer', 'label': '🏦 تحويل بنكي / صرافة'},
      {'key': 'cheque', 'label': '📝 شيك / كمبيالة'},
      {'key': 'offset', 'label': '🤝 مقاصة / تسوية'},
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'طريقة استلام الدفعة:',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: methods.map((m) {
            final isSelected = _selectedPaymentMethod == m['key'];
            return ChoiceChip(
              label: Text(m['label']!),
              selected: isSelected,
              selectedColor: AppColors.paymentGreen.withValues(alpha: 0.15),
              labelStyle: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                color: isSelected
                    ? AppColors.paymentGreen
                    : AppColors.textSecondary,
              ),
              onSelected: (_) =>
                  setState(() => _selectedPaymentMethod = m['key']!),
            );
          }).toList(),
        ),
      ],
    );
  }

  /// حقول تفاصيل التحويل البنكي / الصرافة
  Widget _buildBankTransferFields() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Column(
        children: [
          TextFormField(
            controller: _bankController,
            decoration: const InputDecoration(
              labelText: 'جهة الصرافة / البنك',
              hintText: 'مثال: الكريمي، النجم، جيب، جوالي، بنكك...',
              prefixIcon: Icon(Icons.account_balance_rounded, size: 18),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _refController,
            decoration: const InputDecoration(
              labelText: 'رقم الحوالة / الإشعار المرجعي',
              hintText: 'مثال: 94827104',
              prefixIcon: Icon(Icons.tag_rounded, size: 18),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }

  /// منتقي تاريخ الاستحقاق
  Widget _buildDueDatePicker() {
    final dateText = _dueDate == null
        ? 'تحديد تاريخ الاستحقاق (اختياري)'
        : 'الاستحقاق: ${DateFormat('yyyy/MM/dd', 'ar').format(_dueDate!)}';

    return GestureDetector(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: _dueDate ?? DateTime.now().add(const Duration(days: 30)),
          firstDate: DateTime.now(),
          lastDate: DateTime.now().add(const Duration(days: 730)),
        );
        if (picked != null) {
          setState(() => _dueDate = picked);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Row(
          children: [
            Icon(
              Icons.calendar_month_rounded,
              size: 20,
              color: _dueDate != null
                  ? AppColors.primary
                  : AppColors.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                dateText,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: _dueDate != null
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: _dueDate != null
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                ),
              ),
            ),
            if (_dueDate != null)
              GestureDetector(
                onTap: () => setState(() => _dueDate = null),
                child: const Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: AppColors.textMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
