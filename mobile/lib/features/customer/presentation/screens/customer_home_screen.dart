import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/brand_logo.dart';
import '../../../../shared/widgets/sync_status_banner.dart';
import '../../../../core/finance/currency_info.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import '../../data/models/customer_summary_model.dart';
import '../controllers/customer_controller.dart';

/// شاشة العميل الرئيسية — بيانات حقيقية من الخادم (customer_business_summary /
/// customer_link_requests / ledger_timeline) بلا أي أرقام وهمية.
class CustomerHomeScreen extends ConsumerStatefulWidget {
  const CustomerHomeScreen({super.key});

  @override
  ConsumerState<CustomerHomeScreen> createState() => _CustomerHomeScreenState();
}

class _CustomerHomeScreenState extends ConsumerState<CustomerHomeScreen> {
  final currencyFormatter = NumberFormat('#,##0.##');
  final Set<String> _busyActions = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(customerControllerProvider.notifier).load();
    });
  }

  String _currencySymbol(String code) => CurrencyCatalog.forCode(code).symbol;

  String _relativeTime(String? iso) {
    if (iso == null || iso.isEmpty) return 'لا توجد عمليات بعد';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inHours < 1) return 'منذ ${diff.inMinutes} دقيقة';
    if (diff.inDays < 1) return 'منذ ${diff.inHours} ساعة';
    if (diff.inDays == 1) return 'أمس';
    if (diff.inDays < 30) return 'منذ ${diff.inDays} أيام';
    return DateFormat('yyyy/MM/dd').format(dt);
  }

  Future<void> _respondLinkRequest(
    CustomerLinkRequestModel request,
    bool accept,
  ) async {
    if (_busyActions.contains(request.id)) return;
    setState(() => _busyActions.add(request.id));

    final success = await ref
        .read(customerControllerProvider.notifier)
        .respondToLinkRequest(request.id, accept);

    if (mounted) {
      setState(() => _busyActions.remove(request.id));
      final error = ref.read(customerControllerProvider).errorMessage;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? (accept
                      ? 'تم قبول الربط مع «${request.businessName}» — أصبح حسابك مربوطاً'
                      : 'تم رفض طلب الربط')
                : (error ?? 'تعذر تنفيذ العملية — حاول مرة أخرى'),
          ),
          backgroundColor: success ? AppColors.success : AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
      if (success || error != null) {
        ref.read(customerControllerProvider.notifier).clearError();
      }
    }
  }

  Future<void> _confirmEntry(CustomerPendingEntry entry) async {
    if (_busyActions.contains(entry.id)) return;
    setState(() => _busyActions.add(entry.id));

    final success = await ref
        .read(customerControllerProvider.notifier)
        .confirmEntry(entry.id);

    if (mounted) {
      setState(() => _busyActions.remove(entry.id));
      final error = ref.read(customerControllerProvider).errorMessage;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'تم تأكيد العملية بنجاح ✅'
                : (error ??
                      'تعذر تأكيد العملية — تحقق من اتصالك وحاول مرة أخرى'),
          ),
          backgroundColor: success ? AppColors.success : AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
      if (success || error != null) {
        ref.read(customerControllerProvider.notifier).clearError();
      }
    }
  }

  Future<void> _openDispute(CustomerPendingEntry entry) async {
    String reason = 'wrong_amount';
    final descriptionController = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('تقديم اعتراض'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'لن تُحذف العملية. سيصل الاعتراض إلى المحل لمراجعته.',
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: reason,
                  decoration: const InputDecoration(labelText: 'سبب الاعتراض'),
                  items: const [
                    DropdownMenuItem(
                      value: 'wrong_amount',
                      child: Text('المبلغ غير صحيح'),
                    ),
                    DropdownMenuItem(
                      value: 'unknown_transaction',
                      child: Text('لم أقم بهذه العملية'),
                    ),
                    DropdownMenuItem(
                      value: 'duplicate',
                      child: Text('العملية مكررة'),
                    ),
                    DropdownMenuItem(
                      value: 'already_paid',
                      child: Text('دفعت هذا المبلغ مسبقاً'),
                    ),
                    DropdownMenuItem(
                      value: 'wrong_date',
                      child: Text('التاريخ غير صحيح'),
                    ),
                    DropdownMenuItem(
                      value: 'wrong_description',
                      child: Text('الوصف غير صحيح'),
                    ),
                    DropdownMenuItem(value: 'other', child: Text('سبب آخر')),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => reason = value);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descriptionController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'التوضيح *',
                    hintText: 'اكتب ما الذي يحتاج إلى تصحيح',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                if (descriptionController.text.trim().isEmpty) return;
                Navigator.pop(dialogContext, true);
              },
              child: const Text('إرسال الاعتراض'),
            ),
          ],
        ),
      ),
    );
    if (submitted != true || !mounted) return;
    setState(() => _busyActions.add(entry.id));
    final success = await ref
        .read(customerControllerProvider.notifier)
        .openDispute(
          entryId: entry.id,
          reason: reason,
          description: descriptionController.text,
        );
    if (!mounted) return;
    setState(() => _busyActions.remove(entry.id));
    final error = ref.read(customerControllerProvider).errorMessage;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'تم إرسال اعتراضك إلى المحل'
              : (error ?? 'تعذر إرسال الاعتراض'),
        ),
        backgroundColor: success ? AppColors.success : AppColors.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
    ref.read(customerControllerProvider.notifier).clearError();
  }

  /// يفتح قائمة القيود المعلقة بانتظار تأكيد العميل (بدل SnackBar الوهمي)
  void _openPendingEntriesSheet(
    CustomerHomeState state, {
    String? businessCustomerId,
  }) {
    final entries = businessCustomerId == null
        ? state.pendingEntries
        : state.pendingEntries
              .where((e) => e.businessCustomerId == businessCustomerId)
              .toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.borderLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'عمليات بانتظار تأكيدك',
                style: AppTypography.titleMedium(color: AppColors.textPrimary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'راجع كل عملية سجلها المحل ثم أكّدها لتوثيقها رسمياً',
                style: AppTypography.caption(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: [
                      const Icon(
                        AppIcons.shieldCheck,
                        size: 44,
                        color: AppColors.success,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'لا توجد عمليات بانتظار التأكيد',
                        style: AppTypography.titleSmall(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, index) {
                      final entry = entries[index];
                      final isDebit = entry.direction == 'debit';
                      final isBusy = _busyActions.contains(entry.id);
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.backgroundLight,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.borderLight),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color:
                                    (isDebit
                                            ? AppColors.debtRed
                                            : AppColors.paymentGreen)
                                        .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                isDebit ? AppIcons.debt : AppIcons.payment,
                                size: 18,
                                color: isDebit
                                    ? AppColors.debtRed
                                    : AppColors.paymentGreen,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.description.isNotEmpty
                                        ? entry.description
                                        : (isDebit ? 'قيد دين' : 'دفعة سداد'),
                                    style: AppTypography.titleSmall(
                                      color: AppColors.textPrimary,
                                    ).copyWith(fontSize: 12),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${currencyFormatter.format(entry.amount)} ${_currencySymbol(entry.currencyCode)} • ${_relativeTime(entry.occurredAt)}',
                                    style: AppTypography.caption(
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            isBusy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.paymentGreen,
                                    ),
                                  )
                                : Column(
                                    children: [
                                      ElevatedButton(
                                        onPressed: () {
                                          Navigator.pop(ctx);
                                          _confirmEntry(entry);
                                        },
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor:
                                              AppColors.paymentGreen,
                                          foregroundColor: Colors.white,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        child: const Text(
                                          'تأكيد',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: () {
                                          Navigator.pop(ctx);
                                          _openDispute(entry);
                                        },
                                        style: TextButton.styleFrom(
                                          foregroundColor: AppColors.debtRed,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        child: const Text(
                                          'اعتراض',
                                          style: TextStyle(fontSize: 11),
                                        ),
                                      ),
                                    ],
                                  ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final state = ref.watch(customerControllerProvider);
    final userName = authState.displayName ?? 'العميل';

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceLight,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        title: Row(
          children: [
            const BrandLogo.icon(width: 32, height: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'مرحباً بك، $userName',
                    style: AppTypography.titleSmall(
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    'حساب العميل الموحد',
                    style: AppTypography.caption(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'تسجيل الخروج',
            icon: const Icon(
              Icons.logout_rounded,
              color: AppColors.textSecondary,
            ),
            onPressed: () async {
              await ref.read(authControllerProvider.notifier).signOut();
              if (context.mounted) {
                Navigator.pushNamedAndRemoveUntil(
                  context,
                  AppRoutes.login,
                  (r) => false,
                );
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncStatusBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () =>
                  ref.read(customerControllerProvider.notifier).load(),
              color: AppColors.primary,
              child: _buildBody(state),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(CustomerHomeState state) {
    // 1. التحميل الأول
    if (state.isLoading &&
        state.summaries.isEmpty &&
        state.errorMessage == null) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    // 2. خطأ التحميل — رسالة واضحة مع إعادة المحاولة (بدل الصمت)
    if (state.errorMessage != null && state.summaries.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(32),
        children: [
          const SizedBox(height: 60),
          const Icon(AppIcons.offline, size: 54, color: AppColors.error),
          const SizedBox(height: 16),
          Text(
            'تعذر تحميل بياناتك',
            style: AppTypography.titleMedium(color: AppColors.textPrimary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            state.errorMessage!,
            style: AppTypography.bodySmall(color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () =>
                ref.read(customerControllerProvider.notifier).load(),
            icon: const Icon(AppIcons.sync, size: 18),
            label: const Text('إعادة المحاولة'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      );
    }

    // 3. لا حساب عميل مرتبط بهذا المستخدم (حالة مشروعة وليست خطأ)
    if (!state.hasCustomerAccount) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(32),
        children: [
          const SizedBox(height: 60),
          Icon(
            AppIcons.store,
            size: 54,
            color: AppColors.textSecondary.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 16),
          Text(
            'لا يوجد حساب عميل مرتبط بعد',
            style: AppTypography.titleMedium(color: AppColors.textPrimary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'عندما يضيفك محل تجاري برقم هاتفك وترسل له طلب ربط، ستظهر حساباتك وديونك هنا.',
            style: AppTypography.bodySmall(color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
        ],
      );
    }

    // 4. المحتوى الحقيقي
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSummaryHeader(state),
          const SizedBox(height: 20),
          if (state.linkRequests.isNotEmpty) ...[
            _buildLinkRequestsSection(state),
            const SizedBox(height: 24),
          ],
          _buildBusinessesSection(state),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  /// بطاقة الملخص المالي المجمع — إجماليات مفصولة بالعملة (ممنوع جمع عملتين في رقم واحد)
  Widget _buildSummaryHeader(CustomerHomeState state) {
    // تجميع المستحق على العميل (الأرصدة الموجبة) لكل عملة على حدة
    final Map<String, double> owedByCurrency = {};
    for (final s in state.summaries) {
      if (s.currentBalance > 0) {
        owedByCurrency[s.currencyCode] =
            (owedByCurrency[s.currencyCode] ?? 0.0) + s.currentBalance;
      }
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      decoration: const BoxDecoration(
        color: AppColors.primaryDark,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Column(
          children: [
            Text(
              'إجمالي المبالغ المستحقة عليك لجميع المحلات',
              style: AppTypography.caption(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            if (owedByCurrency.isEmpty)
              const Text(
                'لا توجد مبالغ مستحقة عليك 🎉',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: AppColors.paymentGreen,
                ),
              )
            else
              ...owedByCurrency.entries.map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${currencyFormatter.format(e.value)} ${_currencySymbol(e.key)}',
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: AppColors.debtRed,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              state.summaries.isEmpty
                  ? 'غير مرتبط بأي محل بعد'
                  : 'مرتبط بـ ${state.summaries.length} ${state.summaries.length == 1 ? 'محل تجاري' : 'محلات تجارية'}',
              style: AppTypography.caption(color: AppColors.accentGold),
            ),
          ],
        ),
      ),
    );
  }

  /// طلبات الربط الحقيقية مع زري قبول/رفض
  Widget _buildLinkRequestsSection(CustomerHomeState state) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'طلبات ربط بانتظار ردك (${state.linkRequests.length})',
            style: AppTypography.titleMedium(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 10),
          ...state.linkRequests.map((request) {
            final isBusy = _busyActions.contains(request.id);
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.accentGold.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.accentGold.withValues(alpha: 0.3),
                ),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.accentGold,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          AppIcons.notifications,
                          color: AppColors.primaryDark,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'طلب ربط حساب جديد',
                              style: AppTypography.titleSmall(
                                color: AppColors.primaryDark,
                              ),
                            ),
                            Text(
                              'ترغب «${request.businessName}»${request.businessCity != null ? ' (${request.businessCity})' : ''} بربط حسابك لعرض المشتريات والديون.',
                              style: AppTypography.caption(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: isBusy
                              ? null
                              : () => _respondLinkRequest(request, true),
                          icon: const Icon(AppIcons.check, size: 16),
                          label: const Text('قبول الربط'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.paymentGreen,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: isBusy
                              ? null
                              : () => _respondLinkRequest(request, false),
                          icon: const Icon(AppIcons.close, size: 16),
                          label: const Text('رفض'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.debtRed,
                            side: const BorderSide(color: AppColors.debtRed),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ).animate().fadeIn(duration: 200.ms);
          }),
        ],
      ),
    );
  }

  /// قائمة المحلات المرتبطة الحقيقية
  Widget _buildBusinessesSection(CustomerHomeState state) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'سجلات المحلات المرتبطة',
                style: AppTypography.titleMedium(color: AppColors.textPrimary),
              ),
              Text(
                state.summaries.isEmpty
                    ? 'لا يوجد'
                    : '${state.summaries.length} محلات',
                style: AppTypography.caption(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (state.summaries.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Icon(
                  AppIcons.offline,
                  size: 44,
                  color: AppColors.textSecondary.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 12),
                Text(
                  'لا توجد محلات مرتبطة بحسابك بعد',
                  style: AppTypography.titleSmall(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 6),
                Text(
                  'اطلب من محلك إضافتك برقم هاتفك ليظهر سجلك هنا.',
                  style: AppTypography.caption(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: state.summaries
                  .map(
                    (summary) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _buildBusinessCard(state, summary),
                    ),
                  )
                  .toList(),
            ),
          ),
      ],
    );
  }

  Widget _buildBusinessCard(
    CustomerHomeState state,
    CustomerBusinessSummary summary,
  ) {
    final balance = summary.currentBalance;
    final isZero = balance == 0;
    final owedOnCustomer = balance > 0; // موجب = مستحق على العميل
    final pendingCount = state.pendingEntries
        .where((e) => e.businessCustomerId == summary.businessCustomerId)
        .length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.borderLight),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: AppColors.primaryLight,
                radius: 20,
                child: const Icon(
                  AppIcons.store,
                  color: AppColors.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary.businessName,
                      style: AppTypography.titleSmall(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      summary.businessType ?? 'محل تجاري',
                      style: AppTypography.caption(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 24, color: AppColors.borderLight),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isZero
                          ? 'الحساب متزن (خالص)'
                          : (owedOnCustomer
                                ? 'المبلغ المستحق عليك:'
                                : 'مبلغ مقدم لصالحك:'),
                      style: AppTypography.caption(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${currencyFormatter.format(balance.abs())} ${_currencySymbol(summary.currencyCode)}',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: isZero
                            ? AppColors.textMuted
                            : (owedOnCustomer
                                  ? AppColors.debtRed
                                  : AppColors.paymentGreen),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${summary.entryCount} عملية • آخر حركة: ${_relativeTime(summary.lastEntryAt)}',
                      style: AppTypography.caption(
                        color: AppColors.textMuted,
                      ).copyWith(fontSize: 10),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () => _openPendingEntriesSheet(
                  state,
                  businessCustomerId: summary.businessCustomerId,
                ),
                icon: const Icon(AppIcons.shieldCheck, size: 16),
                label: Text(
                  pendingCount > 0 ? 'تأكيد ($pendingCount)' : 'تأكيد السجل',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.paymentGreen,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ).animate().fadeIn(duration: 200.ms);
  }
}
