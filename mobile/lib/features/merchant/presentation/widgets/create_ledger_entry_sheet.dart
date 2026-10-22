import 'package:muthbat/shared/widgets/top_notice.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../../../app/theme/app_colors.dart';
import '../../../../core/finance/currency_info.dart';
import '../../../../core/finance/money.dart';
import '../controllers/merchant_controller.dart';
import '../../data/models/business_customer_model.dart';
import 'attachment_picker_widget.dart';

/// شاشة تسجيل العمليات المالية الاحترافية (تعدد العملات + تصنيف الأغراض وطرق السداد)
class CreateLedgerEntrySheet extends ConsumerStatefulWidget {
  /// One full-page entry flow shared by the dashboard and customer ledger.
  static Future<bool?> open(
    BuildContext context, {
    required BusinessCustomerModel customer,
    String initialType = 'debt',
  }) => Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      builder: (_) =>
          CreateLedgerEntrySheet(customer: customer, initialType: initialType),
    ),
  );
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
    if (_isSubmitting) return;
    if (!_formKey.currentState!.validate()) return;

    final money = Money.fromCurrencyText(
      _amountController.text.trim(),
      decimalScale: _currencyInfo(_selectedCurrency).decimalScale,
    );
    setState(() => _isSubmitting = true);
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
                  color: AppColors.white,
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
    final accent = isDebt ? AppColors.debtRed : AppColors.primary;
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        toolbarHeight: 60,
        centerTitle: false,
        titleSpacing: 0,
        leadingWidth: 52,
        leading: IconButton(
          tooltip: 'رجوع',
          onPressed: _isSubmitting ? null : () => Navigator.maybePop(context),
          icon: const Icon(Icons.arrow_back_rounded, size: 22),
        ),
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isDebt ? Icons.north_east_rounded : Icons.south_west_rounded,
                size: 19,
                color: accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isDebt ? 'تسجيل دين' : 'تسجيل سداد',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 16),
          ],
        ),
        backgroundColor: AppColors.backgroundLight,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: const Border(bottom: BorderSide(color: AppColors.borderLight)),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          decoration: const BoxDecoration(
            color: AppColors.white,
            border: Border(top: BorderSide(color: AppColors.borderLight)),
          ),
          child: FilledButton.icon(
            onPressed: _isSubmitting ? null : _handleSubmit,
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: AppColors.white,
              minimumSize: const Size.fromHeight(54),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: _isSubmitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.white,
                    ),
                  )
                : const Icon(Icons.check_rounded, size: 22),
            label: Text(
              _isSubmitting
                  ? 'جارٍ الحفظ…'
                  : isDebt
                  ? 'حفظ الدين'
                  : 'حفظ السداد',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildCustomerInfoCard(),
                const SizedBox(height: 12),
                _buildTypeSwitcher(),
                const SizedBox(height: 16),
                _sectionTitle('تفاصيل العملية', Icons.receipt_long_outlined),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.borderLight),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildAmountInput(),
                      const SizedBox(height: 14),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final category = isDebt
                              ? _buildDebtCategorySelector()
                              : _buildPaymentMethodSelector();
                          if (constraints.maxWidth < 300 ||
                              MediaQuery.textScalerOf(context).scale(14) > 18) {
                            return Column(
                              children: [
                                _buildCurrencySelector(),
                                const SizedBox(height: 12),
                                category,
                              ],
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _buildCurrencySelector()),
                              const SizedBox(width: 10),
                              Expanded(child: category),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _descController,
                        enabled: !_isSubmitting,
                        minLines: 1,
                        maxLines: 3,
                        maxLength: 500,
                        style: const TextStyle(fontSize: 14, height: 1.4),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          counterText: '',
                          labelText: 'البيان',
                          alignLabelWithHint: true,
                          hintText: isDebt
                              ? 'اكتب سبب الدين أو تفاصيل المشتريات'
                              : 'اكتب تفاصيل الدفعة',
                          prefixIcon: const Icon(Icons.notes_rounded, size: 20),
                        ),
                        validator: (value) =>
                            value == null || value.trim().length < 2
                            ? 'اكتب بيانًا من حرفين على الأقل'
                            : null,
                      ),
                      if (!isDebt &&
                          _selectedPaymentMethod == 'bank_transfer') ...[
                        const SizedBox(height: 16),
                        _buildBankTransferFields(),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.borderLight),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ExpansionTile(
                    shape: const Border(),
                    collapsedShape: const Border(),
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    tilePadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 2,
                    ),
                    leading: const Icon(Icons.tune_rounded, size: 19),
                    title: const Text(
                      'تفاصيل إضافية',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      isDebt
                          ? 'تاريخ الاستحقاق والمرفقات · اختياري'
                          : 'المرفقات · اختياري',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    maintainState: true,
                    children: [
                      if (isDebt) ...[
                        _buildDueDatePicker(),
                        const SizedBox(height: 12),
                      ],
                      AttachmentPickerWidget(
                        onFileSelected: (file) =>
                            setState(() => _attachedFile = file),
                        label: 'إرفاق فاتورة أو سند قبض',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, IconData icon) => Row(
    children: [
      Icon(icon, size: 20, color: AppColors.primary),
      const SizedBox(width: 8),
      Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: AppColors.textPrimary,
        ),
      ),
    ],
  );

  /// بطاقة ملخص العميل وأرصدته متعددة العملات
  Widget _buildCustomerInfoCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: AppColors.primaryContainer,
            radius: 19,
            child: const Icon(
              Icons.person_outline_rounded,
              color: AppColors.primary,
              size: 23,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'العميل',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  widget.customer.localDisplayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'sans-serif',
                    fontFamilyFallback: ['Arial'],
                    fontSize: 16,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
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
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.balanceColor(bal),
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
        style: TextStyle(fontSize: 13, color: AppColors.textMuted),
      );
    }

    return Text(
      balanceStrings.join(' | '),
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: AppColors.secondary,
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// مفتاح التبديل بين دين ودفعة
  Widget _buildTypeSwitcher() => SegmentedButton<String>(
    showSelectedIcon: false,
    style: SegmentedButton.styleFrom(
      selectedBackgroundColor: _entryType == 'debt'
          ? AppColors.debtRed
          : AppColors.primary,
      selectedForegroundColor: AppColors.white,
      backgroundColor: AppColors.white,
      foregroundColor: AppColors.textSecondary,
      padding: const EdgeInsets.symmetric(vertical: 8),
      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
    ),
    segments: const [
      ButtonSegment(
        value: 'debt',
        label: Text('دين'),
        icon: Icon(Icons.north_east_rounded, size: 19),
      ),
      ButtonSegment(
        value: 'payment',
        label: Text('سداد'),
        icon: Icon(Icons.south_west_rounded, size: 19),
      ),
    ],
    selected: {_entryType},
    onSelectionChanged: _isSubmitting
        ? null
        : (values) => setState(() {
            _entryType = values.single;
            _selectedCategory = _entryType == 'debt' ? 'goods' : 'cash';
          }),
  );

  Widget _buildCurrencySelector() {
    final supported = <String>{
      _selectedCurrency,
      ...ref.read(merchantControllerProvider).supportedCurrencies,
      ...widget.customer.currencyBalances.keys.map(
        (code) => code.toUpperCase(),
      ),
    }.where(CurrencyCatalog.allowedCodes.contains).toList();
    return DropdownButtonFormField<String>(
      initialValue: _selectedCurrency,
      isExpanded: true,
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        labelText: 'العملة',
      ),
      items: supported
          .map(
            (code) => DropdownMenuItem(
              value: code,
              child: Text(
                _currencyInfo(code).name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          )
          .toList(),
      onChanged: _isSubmitting
          ? null
          : (value) {
              if (value != null) setState(() => _selectedCurrency = value);
            },
    );
  }

  /// حقل إدخال المبلغ المالي
  Widget _buildAmountInput() {
    final currSymbol = _currencyInfo(_selectedCurrency).symbol;

    return TextFormField(
      controller: _amountController,
      enabled: !_isSubmitting,
      textDirection: TextDirection.ltr,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w900,
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        labelText: 'المبلغ',
        hintText: '0.00',
        prefixIcon: const Icon(Icons.payments_outlined, size: 22),
        suffixText: currSymbol,
        suffixStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w800,
          color: AppColors.primary,
        ),
        filled: true,
        fillColor: AppColors.backgroundLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.neutralBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.neutralBorder),
        ),
      ),
      validator: (val) {
        if (val == null || val.trim().isEmpty) return 'يرجى إدخال المبلغ';
        final decimalScale = _currencyInfo(_selectedCurrency).decimalScale;
        Money? parsedMoney;
        try {
          parsedMoney = Money.fromCurrencyText(
            val.trim(),
            decimalScale: decimalScale,
          );
        } on FormatException {
          if (Money.tryParse(val.trim()) != null) {
            return 'تسمح عملة $_selectedCurrency بـ $decimalScale منازل عشرية فقط';
          }
          return 'يرجى إدخال مبلغ صحيح';
        }
        final parsed = parsedMoney.toDouble();
        if (!parsed.isFinite) {
          return 'Ø§Ù„Ù…Ø¨Ù„Øº ØºÙŠØ± ØµØ§Ù„Ø­';
        }
        if (parsed > 900000000000000) {
          return 'Ø§Ù„Ù…Ø¨Ù„Øº Ø£ÙƒØ¨Ø± Ù…Ù† Ø§Ù„Ø­Ø¯ Ø§Ù„Ù…Ø³Ù…ÙˆØ­';
        }
        final normalized = val.trim().replaceAll(',', '.');
        final fraction = normalized.contains('.')
            ? normalized.split('.').last
            : '';
        if (fraction.length > 4) {
          return 'ÙŠØ³Ù…Ø­ Ø¨Ø£Ø±Ø¨Ø¹ Ù…Ù†Ø§Ø²Ù„ Ø¹Ø´Ø±ÙŠØ© ÙƒØ­Ø¯ Ø£Ù‚ØµÙ‰';
        }
        if (parsed <= 0) {
          return 'يرجى إدخال رقم صحيح أكبر من الصفر';
        }
        return null;
      },
    );
  }

  /// تصنيف غرض الدين
  Widget _buildDebtCategorySelector() => _selectionField(
    label: 'التصنيف',
    value: _selectedCategory,
    icon: Icons.category_outlined,
    choices: const {
      'goods': 'بضاعة / مشتريات',
      'cash': 'نقد / قرض مالي',
      'service': 'خدمة / عمل',
      'transfer': 'حوالة عن العميل',
    },
    onChanged: (value) => setState(() => _selectedCategory = value),
  );

  Widget _buildPaymentMethodSelector() => _selectionField(
    label: 'طريقة السداد',
    value: _selectedPaymentMethod,
    icon: Icons.account_balance_wallet_outlined,
    choices: const {
      'cash': 'نقدًا',
      'bank_transfer': 'تحويل بنكي / صرافة',
      'cheque': 'شيك / كمبيالة',
      'offset': 'مقاصة / تسوية',
    },
    onChanged: (value) => setState(() => _selectedPaymentMethod = value),
  );

  Widget _selectionField({
    required String label,
    required String value,
    required IconData icon,
    required Map<String, String> choices,
    required ValueChanged<String> onChanged,
  }) => DropdownButtonFormField<String>(
    key: ValueKey(label),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      labelText: label,
    ),
    items: choices.entries
        .map(
          (entry) => DropdownMenuItem(
            value: entry.key,
            child: Text(
              entry.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        )
        .toList(),
    onChanged: _isSubmitting
        ? null
        : (selected) {
            if (selected != null) onChanged(selected);
          },
  );

  /// حقول تفاصيل التحويل البنكي / الصرافة
  Widget _buildBankTransferFields() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.successSurfaceSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.successBorder),
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
          color: AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.borderLight),
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
                  fontSize: 14,
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
