import 'package:muthbat/shared/widgets/top_notice.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/finance/currency_info.dart';
import '../../../../core/services/statement_sharing_service.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_typography.dart';
import '../../data/models/business_customer_model.dart';
import '../../data/models/ledger_entry_model.dart';
import '../controllers/merchant_controller.dart';
import '../widgets/create_ledger_entry_sheet.dart';
import '../widgets/discount_entry_sheet.dart';
import '../widgets/generate_statement_sheet.dart';
import '../widgets/reversal_confirm_sheet.dart';

class CustomerLedgerScreen extends ConsumerStatefulWidget {
  final BusinessCustomerModel customer;

  const CustomerLedgerScreen({super.key, required this.customer});

  @override
  ConsumerState<CustomerLedgerScreen> createState() =>
      _CustomerLedgerScreenState();
}

class _CustomerLedgerScreenState extends ConsumerState<CustomerLedgerScreen> {
  late BusinessCustomerModel _customer;
  List<LedgerEntryModel> _entries = [];
  bool _isLoading = true;
  String? _selectedCurrencyFilter; // null = all, or 'YER', 'SAR', 'USD'

  String _currencySymbol(String code) => CurrencyCatalog.forCode(code).symbol;

  List<String> get _availableCurrencies => {
    ..._customer.currencyBalances.keys.map((e) => e.toUpperCase()),
    ..._entries.map((e) => e.currencyCode.toUpperCase()),
  }.toList()..sort();

  @override
  void initState() {
    super.initState();
    _customer = widget.customer;
    _loadEntries();
  }

  Future<void> _loadEntries() async {
    setState(() => _isLoading = true);
    final repo = ref.read(merchantRepositoryProvider);

    // تحديث بيانات العميل الحالي
    final updatedCust = await repo.getCustomer(_customer.id);
    if (updatedCust != null) {
      _customer = updatedCust;
    }

    final list = await repo.getLedgerEntries(
      _customer.id,
      currencyCode: _selectedCurrencyFilter,
    );
    if (mounted) {
      setState(() {
        _entries = list;
        _isLoading = false;
      });
    }
  }

  void _openCreateEntry(String type) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          CreateLedgerEntrySheet(customer: _customer, initialType: type),
    );

    if (result == true) {
      await _loadEntries();
      ref.read(merchantControllerProvider.notifier).loadDashboard();
    }
  }

  void _openDiscount() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DiscountEntrySheet(customer: _customer),
    );

    if (result == true) {
      await _loadEntries();
      ref.read(merchantControllerProvider.notifier).loadDashboard();
    }
  }

  void _openReversal(LedgerEntryModel entry) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          ReversalConfirmSheet(entry: entry, businessCustomerId: _customer.id),
    );

    if (result == true) {
      await _loadEntries();
      ref.read(merchantControllerProvider.notifier).loadDashboard();
    }
  }

  void _openStatement() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GenerateStatementSheet(customer: _customer),
    );
  }

  void _showEntryActions(LedgerEntryModel entry) {
    if (entry.entryType == 'reversal' || entry.isReversed) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
              'إجراءات العملية',
              style: AppTypography.titleMedium(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 4),
            Text(
              entry.description,
              style: AppTypography.caption(color: AppColors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 20),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(AppIcons.reversal, color: AppColors.warning),
              ),
              title: const Text(
                'عكس القيد (إلغاء العملية)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: const Text(
                'إدراج قيد تسوية معاكس للحفاظ على تدقيق السجل',
              ),
              onTap: () {
                Navigator.pop(ctx);
                _openReversal(entry);
              },
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(AppIcons.whatsapp, color: AppColors.primary),
              ),
              title: const Text(
                'مشاركة سند مالي عبر واتساب',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: const Text(
                'إرسال سند موثق بتفاصيل القيد والرصيد المتبقي للعميل',
              ),
              onTap: () async {
                Navigator.pop(ctx);
                final bizName = ref
                    .read(merchantControllerProvider)
                    .businessName;
                final sent =
                    await StatementSharingService.shareReceiptViaWhatsApp(
                      businessName: bizName.isNotEmpty
                          ? bizName
                          : 'دفتر الحساب',
                      customer: _customer,
                      entry: entry,
                    );
                if (!sent && mounted) {
                  TopNotice.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'تعذر فتح تطبيق واتساب. يرجى التأكد من تثبيته على جهازك.',
                      ),
                      backgroundColor: AppColors.warning,
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEntryDetails(LedgerEntryModel entry) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LedgerEntryDetailsSheet(
        entry: entry,
        currencySymbol: _currencySymbol(entry.currencyCode),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final formatter = NumberFormat('#,##0.##', 'ar');

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceLight,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              _customer.localDisplayName,
              style: AppTypography.titleMedium(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w800),
            ),
            const Text(
              'دفتر الحساب والذمم المالية',
              style: const TextStyle(
                fontSize: 10,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(AppIcons.whatsapp),
            tooltip: 'مشاركة ملخص الحساب عبر واتساب',
            onPressed: () async {
              final bizName = ref.read(merchantControllerProvider).businessName;
              final sent =
                  await StatementSharingService.shareCustomerSummaryViaWhatsApp(
                    businessName: bizName.isNotEmpty ? bizName : 'دفتر الحساب',
                    customer: _customer,
                    recentEntries: _entries,
                  );
              if (!sent && mounted) {
                TopNotice.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'تعذر فتح تطبيق واتساب. يرجى التأكد من تثبيته على جهازك.',
                    ),
                    backgroundColor: AppColors.warning,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'تصدير كشف حساب',
            onPressed: _openStatement,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadEntries,
        color: AppColors.primary,
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            // 1. بطاقة الرصيد والبيانات العامة للعميل
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                  decoration: BoxDecoration(
                    gradient: AppColors.brandGradient,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.14),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      // رقم الهاتف ومعلومات الربط
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.phone_outlined,
                                color: Colors.white70,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _customer.phone ?? 'بدون رقم مسجل',
                                style: AppTypography.bodySmall(
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _customer.linkStatus == 'linked'
                                  ? AppColors.paymentGreen.withValues(
                                      alpha: 0.2,
                                    )
                                  : AppColors.accentGold.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _customer.linkStatus == 'linked'
                                      ? Icons.verified_rounded
                                      : Icons.link_off_rounded,
                                  size: 14,
                                  color: _customer.linkStatus == 'linked'
                                      ? AppColors.paymentGreen
                                      : AppColors.accentGold,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _customer.linkStatus == 'linked'
                                      ? 'حساب موثق ومربوط'
                                      : 'حساب محلي غير مربوط',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: _customer.linkStatus == 'linked'
                                        ? AppColors.paymentGreen
                                        : AppColors.accentGold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // بطاقة الأرصدة متعددة العملات
                      _buildHomeStyleBalanceCard(formatter),

                      const SizedBox(height: 18),

                      // أزرار الإجراء السريع (تسجيل دين / سداد / خصم)
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => _openCreateEntry('debt'),
                              icon: const Icon(AppIcons.debt, size: 18),
                              label: const Text(
                                'دين (+)',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.debtRed,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 13,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => _openCreateEntry('payment'),
                              icon: const Icon(AppIcons.payment, size: 18),
                              label: const Text(
                                'سداد (-)',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.paymentGreen,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 13,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _openDiscount,
                              icon: const Icon(AppIcons.discount, size: 18),
                              label: const Text(
                                'خصم',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.accentGold,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 13,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // 2. شريط فلترة العملات (إذا كان هناك قيود بعملات مختلفة)
            ),

            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Row(
                  children: [
                    Text(
                      'كشف العمليات (${_entries.length})',
                      style: AppTypography.titleMedium(
                        color: AppColors.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w800),
                    ),
                    const Spacer(),
                    // فلاتر العملات
                    _buildCurrencyFilterChip(null, 'الكل'),
                    const SizedBox(width: 4),
                    ..._availableCurrencies.expand(
                      (code) => [
                        const SizedBox(width: 4),
                        _buildCurrencyFilterChip(code, _currencySymbol(code)),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // 3. قائمة العمليات
            if (_isLoading)
              const SliverFillRemaining(
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
              )
            else if (_entries.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          AppIcons.statement,
                          size: 54,
                          color: AppColors.textSecondary.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'لا توجد عمليات مسجلة لهذا العميل',
                          style: AppTypography.titleSmall(
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'استخدم الأزرار أعلاه لتسجيل دين أو دفعة جديدة.',
                          style: AppTypography.caption(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 40),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final entry = _entries[index];
                    final isDebt = entry.entryType == 'debt';
                    final isPayment = entry.entryType == 'payment';
                    final isDiscount = entry.entryType == 'discount';
                    final isReversal = entry.entryType == 'reversal';
                    final isReversed = entry.isReversed;
                    final currSymbol = _currencySymbol(entry.currencyCode);

                    // تحديد اللون والأيقونة حسب نوع العملية
                    Color entryColor;
                    IconData entryIcon;
                    String entrySign;
                    if (isReversal) {
                      entryColor = AppColors.warning;
                      entryIcon = AppIcons.reversal;
                      entrySign = entry.direction == 'debit' ? '+' : '-';
                    } else if (isDebt) {
                      entryColor = AppColors.debtRed;
                      entryIcon = AppIcons.debt;
                      entrySign = '+';
                    } else if (isPayment) {
                      entryColor = AppColors.paymentGreen;
                      entryIcon = AppIcons.payment;
                      entrySign = '-';
                    } else if (isDiscount) {
                      entryColor = AppColors.accentGold;
                      entryIcon = AppIcons.discount;
                      entrySign = '-';
                    } else {
                      entryColor = AppColors.info;
                      entryIcon = AppIcons.balance;
                      entrySign = '';
                    }

                    // أيقونة التصنيف وطريقة السداد
                    String categoryLabel = '';
                    if (entry.category == 'goods') categoryLabel = '📦 بضاعة';
                    if (entry.category == 'cash') categoryLabel = '💵 نقد';
                    if (entry.category == 'service') categoryLabel = '🛠️ خدمة';
                    if (entry.category == 'transfer')
                      categoryLabel = '🔄 حوالة';

                    String paymentLabel = '';
                    if (entry.paymentMethod == 'bank_transfer') {
                      paymentLabel =
                          '🏦 تحويل${entry.bankOrAgentName != null ? " (${entry.bankOrAgentName})" : ""}';
                    } else if (entry.paymentMethod == 'cheque') {
                      paymentLabel = '📝 شيك';
                    }

                    return GestureDetector(
                      onTap: () => _showEntryDetails(entry),
                      onLongPress: () => _showEntryActions(entry),
                      child: Opacity(
                        opacity: isReversed ? 0.5 : 1.0,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isReversed
                                ? AppColors.backgroundLight
                                : Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: isReversed
                                  ? AppColors.warning.withValues(alpha: 0.3)
                                  : AppColors.borderLight,
                            ),
                            boxShadow: isReversed
                                ? []
                                : [
                                    BoxShadow(
                                      color: AppColors.primary.withValues(
                                        alpha: 0.02,
                                      ),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // أيقونة نوع العملية
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: entryColor.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  entryIcon,
                                  color: entryColor,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),

                              // تفاصيل البيان والتاريخ والتصنيفات
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            entry.description.isNotEmpty
                                                ? entry.description
                                                : (isDebt
                                                      ? 'قيد دين'
                                                      : 'سداد دفعة'),
                                            style:
                                                AppTypography.titleSmall(
                                                  color: isReversed
                                                      ? AppColors.textSecondary
                                                      : AppColors.textPrimary,
                                                ).copyWith(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 13,
                                                ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (isReversal ||
                                            isDiscount ||
                                            isReversed)
                                          Container(
                                            margin: const EdgeInsets.only(
                                              right: 6,
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: isReversed
                                                  ? AppColors.warning
                                                        .withValues(alpha: 0.15)
                                                  : (isReversal
                                                        ? AppColors.warning
                                                              .withValues(
                                                                alpha: 0.15,
                                                              )
                                                        : AppColors.accentGold
                                                              .withValues(
                                                                alpha: 0.15,
                                                              )),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              isReversed
                                                  ? 'مُلغى'
                                                  : (isReversal
                                                        ? 'عكس'
                                                        : 'خصم'),
                                              style: TextStyle(
                                                fontSize: 9,
                                                fontWeight: FontWeight.bold,
                                                color: isReversed || isReversal
                                                    ? AppColors.warning
                                                    : AppColors.accentGold,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),

                                    // شارات التصنيف وطريقة السداد
                                    Wrap(
                                      spacing: 4,
                                      runSpacing: 4,
                                      children: [
                                        if ((entry.localCategoryLabel ??
                                                categoryLabel)
                                            .isNotEmpty)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 5,
                                              vertical: 1.5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: AppColors.badgeGoodsBg,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              entry.localCategoryLabel ??
                                                  categoryLabel,
                                              style: const TextStyle(
                                                fontSize: 9,
                                                color: AppColors.badgeGoodsText,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        if (paymentLabel.isNotEmpty)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 5,
                                              vertical: 1.5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: AppColors.badgeCashBg,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              paymentLabel,
                                              style: const TextStyle(
                                                fontSize: 9,
                                                color: AppColors.badgeCashText,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        if (entry.referenceNumber != null)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 5,
                                              vertical: 1.5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: AppColors.badgeRefBg,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              'مرجع: ${entry.referenceNumber}',
                                              style: const TextStyle(
                                                fontSize: 9,
                                                color: AppColors.badgeRefText,
                                              ),
                                            ),
                                          ),
                                        if (entry.attachmentPath != null &&
                                            entry.attachmentPath!
                                                .trim()
                                                .isNotEmpty)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 5,
                                              vertical: 1.5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: AppColors.primaryContainer,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: const Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Icons.attach_file_rounded,
                                                  size: 10,
                                                  color: AppColors.primary,
                                                ),
                                                SizedBox(width: 2),
                                                Text(
                                                  'مرفق',
                                                  style: TextStyle(
                                                    fontSize: 9,
                                                    color: AppColors.primary,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),

                                    const SizedBox(height: 4),
                                    Text(
                                      DateFormat(
                                        'yyyy/MM/dd - hh:mm a',
                                        'ar',
                                      ).format(
                                        DateTime.parse(entry.occurredAt),
                                      ),
                                      style: AppTypography.caption(
                                        color: AppColors.textSecondary,
                                      ).copyWith(fontSize: 10),
                                    ),
                                    if (entry.dueDate != null) ...[
                                      const SizedBox(height: 3),
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.event_available_rounded,
                                            size: 12,
                                            color: AppColors.accentGold,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            'تاريخ الاستحقاق: ${entry.dueDate}',
                                            style: AppTypography.caption(
                                              color: AppColors.accentGold,
                                            ).copyWith(fontSize: 10),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),

                              // المبلغ المالي والعملة وحالة المزامنة
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    '$entrySign${formatter.format(entry.amount)}',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w900,
                                      color: entryColor,
                                      decoration: isReversed
                                          ? TextDecoration.lineThrough
                                          : null,
                                    ),
                                  ),
                                  Text(
                                    currSymbol,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      color: entryColor,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  if (entry.syncStatus == 'pending_insert')
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 1.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.withValues(
                                          alpha: 0.15,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.hourglass_top_rounded,
                                            size: 9,
                                            color: Colors.orange,
                                          ),
                                          SizedBox(width: 2),
                                          Text(
                                            'معلق',
                                            style: TextStyle(
                                              fontSize: 8,
                                              color: Colors.orange,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  else
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 1.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppColors.successLight,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.cloud_done_rounded,
                                            size: 9,
                                            color: AppColors.success,
                                          ),
                                          SizedBox(width: 2),
                                          Text(
                                            'موثق',
                                            style: TextStyle(
                                              fontSize: 8,
                                              color: AppColors.success,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }, childCount: _entries.length),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// ويدجت عرض أرصدة العملات المتعددة
  Widget _buildHomeStyleBalanceCard(NumberFormat formatter) {
    final balances = _customer.currencyBalances.isEmpty
        ? <String, double>{'YER': _customer.currentBalance}
        : _customer.currencyBalances;
    final first = balances.entries.first;
    final firstInfo = CurrencyCatalog.forCode(first.key);

    Widget breakdownCard({
      required String label,
      required double amount,
      required IconData icon,
      required Color color,
    }) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(icon, size: 13, color: color),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatter.format(amount)} ${firstInfo.symbol}',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.account_balance_wallet_rounded,
                color: AppColors.accentGold,
                size: 15,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '💱 ${firstInfo.name}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                balances.length > 1
                    ? '${balances.length} عملات'
                    : 'حساب العميل',
                style: const TextStyle(
                  color: AppColors.accentGold,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (balances.length == 1)
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                formatter.format(first.value.abs()),
                style: AppTypography.financialAmount(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                firstInfo.symbol,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                first.value > 0 ? 'إجمالي ما لك (ديون)' : 'الرصيد الحالي',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: balances.entries.map((entry) {
              final info = CurrencyCatalog.forCode(entry.key);
              return Text(
                '${formatter.format(entry.value.abs())} ${info.symbol}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              );
            }).toList(),
          ),
        const SizedBox(height: 10),
        if (balances.length == 1)
          Row(
            children: [
              breakdownCard(
                label: 'لك (دفعة مقدمة)',
                amount: first.value < 0 ? first.value.abs() : 0,
                icon: Icons.south_west_rounded,
                color: AppColors.secondaryLight,
              ),
              const SizedBox(width: 8),
              breakdownCard(
                label: 'عليك (دين)',
                amount: first.value > 0 ? first.value : 0,
                icon: Icons.north_east_rounded,
                color: AppColors.accentGold,
              ),
            ],
          )
        else
          Text(
            'الأرصدة معروضة منفصلة حسب العملة',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }

  Widget _buildCurrencyFilterChip(String? currencyCode, String label) {
    final isSelected = _selectedCurrencyFilter == currencyCode;
    return GestureDetector(
      onTap: () {
        setState(() => _selectedCurrencyFilter = currencyCode);
        _loadEntries();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.borderLight,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
            color: isSelected ? Colors.white : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _LedgerEntryDetailsSheet extends StatelessWidget {
  final LedgerEntryModel entry;
  final String currencySymbol;

  const _LedgerEntryDetailsSheet({
    required this.entry,
    required this.currencySymbol,
  });

  String get _attachmentPath => entry.attachmentPath?.trim() ?? '';

  bool get _isRemoteAttachment =>
      _attachmentPath.startsWith('http://') ||
      _attachmentPath.startsWith('https://');

  bool get _isImageAttachment {
    final path = _isRemoteAttachment
        ? (Uri.tryParse(_attachmentPath)?.path ?? _attachmentPath)
        : _attachmentPath;
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif');
  }

  String _typeLabel() {
    switch (entry.entryType) {
      case 'debt':
        return 'دين على العميل';
      case 'payment':
        return 'سداد مستلم';
      case 'discount':
        return 'خصم';
      case 'reversal':
        return 'عكس عملية';
      case 'opening_balance':
        return 'رصيد افتتاحي';
      default:
        return 'عملية مالية';
    }
  }

  String _categoryLabel() {
    if (entry.localCategoryLabel != null) return entry.localCategoryLabel!;
    switch (entry.category) {
      case 'goods':
        return 'بضاعة';
      case 'cash':
        return 'نقد';
      case 'service':
        return 'خدمة';
      case 'transfer':
        return 'حوالة';
      default:
        return 'أخرى';
    }
  }

  String _paymentMethodLabel() {
    switch (entry.paymentMethod) {
      case 'cash':
        return 'نقدًا';
      case 'bank_transfer':
        return entry.bankOrAgentName?.trim().isNotEmpty == true
            ? 'تحويل بنكي — ${entry.bankOrAgentName}'
            : 'تحويل بنكي';
      case 'cheque':
        return 'شيك';
      case 'offset':
        return 'مقاصة';
      default:
        return entry.paymentMethod;
    }
  }

  String _formatDate(String raw) {
    final date = DateTime.tryParse(raw);
    if (date == null) return raw;
    return DateFormat('yyyy/MM/dd - hh:mm a', 'ar').format(date);
  }

  String _fileName() {
    if (_attachmentPath.isEmpty) return 'المرفق';
    return _attachmentPath.split(RegExp(r'[\\/]')).last;
  }

  Color get _accentColor {
    if (entry.entryType == 'payment' || entry.entryType == 'discount') {
      return AppColors.paymentGreen;
    }
    if (entry.entryType == 'reversal') return AppColors.warning;
    return AppColors.debtRed;
  }

  Widget _detailRow({required String label, required String value}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttachment(BuildContext context) {
    if (_attachmentPath.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: const Row(
          children: [
            Icon(Icons.attach_file_rounded, color: AppColors.textMuted),
            SizedBox(width: 8),
            Text(
              'لا يوجد مرفق لهذه العملية',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
      );
    }

    final localFileExists =
        _isRemoteAttachment || File(_attachmentPath).existsSync();
    if (_isImageAttachment && localFileExists) {
      return GestureDetector(
        onTap: () => _showImageViewer(context),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              _imageWidget(height: 210),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 8),
                color: Colors.black.withValues(alpha: 0.55),
                child: const Text(
                  'اضغط لعرض الصورة كاملة',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.insert_drive_file_outlined,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              localFileExists ? _fileName() : 'المرفق غير متاح على هذا الجهاز',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (localFileExists)
            IconButton(
              tooltip: 'فتح المرفق',
              onPressed: () => _openAttachment(context),
              icon: const Icon(
                Icons.open_in_new_rounded,
                color: AppColors.primary,
                size: 20,
              ),
            ),
        ],
      ),
    );
  }

  Widget _imageWidget({double? height}) {
    final image = _isRemoteAttachment
        ? Image.network(
            _attachmentPath,
            height: height,
            width: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _imageErrorWidget(),
          )
        : Image.file(
            File(_attachmentPath),
            height: height,
            width: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _imageErrorWidget(),
          );
    return image;
  }

  Widget _imageErrorWidget() {
    return Container(
      height: 150,
      color: AppColors.backgroundLight,
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            color: AppColors.textMuted,
            size: 32,
          ),
          SizedBox(height: 6),
          Text(
            'تعذر عرض الصورة',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  void _showImageViewer(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 0.8,
              maxScale: 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: _imageWidget(),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black54,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAttachment(BuildContext context) async {
    final uri = _isRemoteAttachment
        ? Uri.tryParse(_attachmentPath)
        : Uri.file(_attachmentPath);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        TopNotice.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر فتح المرفق على هذا الجهاز'),
            backgroundColor: AppColors.warning,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final formatter = NumberFormat('#,##0.####', 'ar');
    final amountSign = entry.direction == 'credit' ? '-' : '+';

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.borderMedium,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'تفاصيل العملية',
                      style: AppTypography.titleMedium(
                        color: AppColors.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    tooltip: 'إغلاق',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _accentColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: _accentColor.withValues(alpha: 0.18),
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      _typeLabel(),
                      style: TextStyle(
                        color: _accentColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '$amountSign${formatter.format(entry.amount)} $currencySymbol',
                      style: TextStyle(
                        color: _accentColor,
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (entry.description.trim().isNotEmpty)
                _detailRow(label: 'البيان', value: entry.description.trim()),
              _detailRow(
                label: 'تاريخ العملية',
                value: _formatDate(entry.occurredAt),
              ),
              _detailRow(label: 'التصنيف', value: _categoryLabel()),
              _detailRow(label: 'طريقة السداد', value: _paymentMethodLabel()),
              if (entry.referenceNumber?.trim().isNotEmpty == true)
                _detailRow(
                  label: 'رقم المرجع',
                  value: entry.referenceNumber!.trim(),
                ),
              if (entry.externalReference?.trim().isNotEmpty == true)
                _detailRow(
                  label: 'المرجع الخارجي',
                  value: entry.externalReference!.trim(),
                ),
              if (entry.dueDate?.trim().isNotEmpty == true)
                _detailRow(
                  label: 'تاريخ الاستحقاق',
                  value: entry.dueDate!.trim(),
                ),
              const Divider(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _statusChip(
                    icon: entry.syncStatus == 'synced'
                        ? Icons.cloud_done_rounded
                        : Icons.hourglass_top_rounded,
                    label: entry.syncStatus == 'synced'
                        ? 'متزامنة'
                        : 'بانتظار المزامنة',
                    color: entry.syncStatus == 'synced'
                        ? AppColors.success
                        : AppColors.warning,
                  ),
                  _statusChip(
                    icon: entry.confirmationStatus == 'confirmed'
                        ? Icons.verified_rounded
                        : Icons.info_outline_rounded,
                    label: entry.confirmationStatus == 'confirmed'
                        ? 'مؤكدة من العميل'
                        : 'حالة التأكيد: ${entry.confirmationStatus}',
                    color: entry.confirmationStatus == 'confirmed'
                        ? AppColors.success
                        : AppColors.textSecondary,
                  ),
                  if (entry.isReversed)
                    _statusChip(
                      icon: Icons.block_rounded,
                      label: 'ملغاة بعكس القيد',
                      color: AppColors.warning,
                    ),
                  if (entry.disputeStatus != 'none')
                    _statusChip(
                      icon: Icons.report_problem_outlined,
                      label: 'نزاع: ${entry.disputeStatus}',
                      color: AppColors.debtRed,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'المرفق',
                style: AppTypography.titleSmall(
                  color: AppColors.textPrimary,
                ).copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              _buildAttachment(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
