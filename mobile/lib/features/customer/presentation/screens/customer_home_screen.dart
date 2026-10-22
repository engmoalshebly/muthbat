import '../../../auth/presentation/sign_out_flow.dart';
import 'dart:ui' as ui;
import '../../../notifications/notifications_screen.dart';
import 'package:muthbat/shared/widgets/top_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../auth/presentation/widgets/workspace_switcher.dart';
import '../../../../shared/widgets/muthbat_bottom_nav.dart';
import '../../../../core/finance/currency_info.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/config/env.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import '../../data/models/customer_summary_model.dart';
import '../controllers/customer_controller.dart';
import 'customer_account_ledger_screen.dart';
import 'customer_balance_overview.dart';
import '../widgets/customer_offline_coverage.dart';
import '../widgets/customer_dispute_button.dart';
import 'customer_entry_details_screen.dart';
import 'customer_disputes_screen.dart';

/// شاشة العميل الرئيسية — بيانات حقيقية من الخادم (customer_business_summary /
/// customer_link_requests / ledger_timeline) بلا أي أرقام وهمية.
class CustomerHomeScreen extends ConsumerStatefulWidget {
  const CustomerHomeScreen({super.key});

  @override
  ConsumerState<CustomerHomeScreen> createState() => _CustomerHomeScreenState();
}

class _CustomerHomeScreenState extends ConsumerState<CustomerHomeScreen>
    with WidgetsBindingObserver {
  final currencyFormatter = NumberFormat('#,##0.##');
  final Set<String> _busyActions = {};
  String _businessSearch = '';
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prepareAndLoadCustomerWorkspace();
    });
  }

  Future<void> _prepareAndLoadCustomerWorkspace() async {
    try {
      await ref
          .read(authControllerProvider.notifier)
          .prepareCustomerWorkspace();
    } catch (error) {
      debugPrint('[CustomerHomeScreen] workspace preparation failed: ');
    }
    if (!mounted) return;
    await ref.read(customerControllerProvider.notifier).load(force: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      ref.read(customerControllerProvider.notifier).refreshIfIdle();
    }
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
      TopNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'حُفظ ردك على طلب الربط. راجع حالة الإرسال؛ الحفظ المحلي لا يعني اكتمال الربط.'
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

  Future<void> _openDispute(CustomerPendingEntry entry) async {
    if (_busyActions.contains(entry.id)) return;
    setState(() => _busyActions.add(entry.id));
    await presentCustomerDispute(
      context,
      ref,
      entryId: entry.id,
      ownerId: ref.read(authControllerProvider).userId,
      entry: entry.toMap(),
    );
    if (!mounted) return;
    setState(() => _busyActions.remove(entry.id));
    await ref.read(customerControllerProvider.notifier).restoreLocal();
  }

  void _openEntry(CustomerPendingEntry entry) {
    final state = ref.read(customerControllerProvider);
    final owner = ref.read(authControllerProvider).userId;
    final summary = state.summaries
        .where(
          (s) =>
              s.businessCustomerId == entry.businessCustomerId &&
              s.currencyCode == entry.currencyCode,
        )
        .firstOrNull;
    Navigator.of(context).push(
      AppRoutes.accountPage(
        builder: (_) => CustomerEntryDetailsScreen(
          businessName: summary?.businessName ?? 'المحل',
          entry: {...entry.toMap(), 'dispute_status': 'none'},
          ownerId: owner,
        ),
      ),
    );
  }

  /// يعرض العمليات المسجلة دون انتظار موافقة العميل.
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
      backgroundColor: AppColors.transparent,
      builder: (ctx) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          decoration: const BoxDecoration(
            color: AppColors.white,
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
                'عمليات مسجلة في حسابك',
                style: AppTypography.titleMedium(color: AppColors.textPrimary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'تُحتسب العمليات مباشرة في رصيدك. يمكنك الاعتراض عند الحاجة من تفاصيل العملية.',
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
                        'لا توجد عمليات جديدة',
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
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
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
                                          _openEntry(entry);
                                        },
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor:
                                              AppColors.paymentGreen,
                                          foregroundColor: AppColors.white,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        child: const Text(
                                          'تفاصيل',
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
    final userName = authState.displayName?.trim().isNotEmpty == true
        ? authState.displayName!.trim()
        : 'حساب العميل';

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: 84,
        backgroundColor: AppColors.backgroundLight,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        titleSpacing: 16,
        title: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                WorkspaceSwitcherButton(
                  currentKind: 'customer',
                  name: userName,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'أهلًا، $userName',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.titleSmall(
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        'حساباتك في مكان واحد',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption(
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!EnvConfig.phoneVerificationEnabled ||
                    state.phoneLinkError != null)
                  _headerMetaChip(
                    icon: Icons.phone_android_outlined,
                    label: state.phoneLinkError != null
                        ? 'تعذر التحقق'
                        : 'التحقق مؤجل',
                    color: state.phoneLinkError != null
                        ? AppColors.error
                        : AppColors.warningStrong,
                    onTap: () => _showAccountStatusDetails(state, null),
                  ),
                if (!EnvConfig.phoneVerificationEnabled ||
                    state.phoneLinkError != null)
                  const SizedBox(width: 5),
                _headerMetaChip(
                  icon: Icons.schedule_rounded,
                  label: state.updatedAt == null
                      ? 'لم يحدّث'
                      : 'تحديث ${DateFormat('HH:mm').format(DateTime.parse(state.updatedAt!).toLocal())}',
                  color: AppColors.textMuted,
                  onTap: () => _showAccountStatusDetails(state, null),
                ),
              ],
            ),
          ],
        ),
        actions: [
          const NotificationBell(workspace: 'customer'),
          PopupMenuButton<String>(
            tooltip: 'إعدادات الحساب',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (value) {
              if (value == 'workspaces') {
                Navigator.pushNamed(context, AppRoutes.workspaces);
              }
              if (value == 'lock') {
                Navigator.pushNamed(context, AppRoutes.appLockSettings);
              }
              if (value == 'logout') {
                confirmAccountSignOut(context, ref);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'workspaces',
                child: Text('مساحات العمل'),
              ),
              PopupMenuItem(
                value: 'lock',
                child: ListTile(
                  leading: Icon(Icons.phonelink_lock_outlined),
                  title: Text('قفل التطبيق'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  leading: Icon(Icons.logout_rounded),
                  title: Text('تسجيل الخروج'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: () =>
                  ref.read(customerControllerProvider.notifier).load(),
              color: AppColors.primary,
              child: _buildBody(state, authState),
            ),
          ),
        ],
      ),
      bottomNavigationBar: MuthbatBottomNav(
        currentIndex: _selectedTab,
        onTap: (index) => setState(() => _selectedTab = index),
        items: const [
          MuthbatNavItem(icon: Icons.home_rounded, label: 'الرئيسية'),
          MuthbatNavItem(icon: Icons.storefront_outlined, label: 'بقالاتي'),
          MuthbatNavItem(icon: Icons.receipt_long_outlined, label: 'القيود'),
          MuthbatNavItem(icon: Icons.person_outline_rounded, label: 'حسابي'),
        ],
      ),
    );
  }

  Widget _headerMetaChip({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _refreshCustomerAccounts() async {
    if (_busyActions.contains('phone-link')) return;
    setState(() => _busyActions.add('phone-link'));
    try {
      await ref.read(customerControllerProvider.notifier).load(force: true);
    } finally {
      if (mounted) setState(() => _busyActions.remove('phone-link'));
    }
  }

  void _showAccountStatusDetails(
    CustomerHomeState state,
    SyncProgress? progress,
  ) {
    final verificationDeferred = !EnvConfig.phoneVerificationEnabled;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'حالة الحساب',
                style: AppTypography.titleMedium(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 12),
              if (verificationDeferred)
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.phone_android_outlined),
                  title: Text('التحقق من ملكية الهاتف مؤجل'),
                  subtitle: Text(
                    'ربط السجلات السابقة بالرقم وحده غير مفعّل حاليًا.',
                  ),
                ),
              if (state.phoneLinkError != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.warning_amber_rounded,
                    color: AppColors.warningStrong,
                  ),
                  title: const Text('تعذر تحديث ربط الهاتف'),
                  subtitle: Text(state.phoneLinkError!),
                  trailing: state.requiresPhoneVerification
                      ? TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                            Navigator.pushNamed(context, AppRoutes.recovery);
                          },
                          child: const Text('استعادة'),
                        )
                      : null,
                ),
              if (state.outbox.isNotEmpty)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.cloud_upload_outlined,
                    color: AppColors.warningStrong,
                  ),
                  title: Text(
                    '${state.outbox.where((a) => a['status'] == 'pending').length} بانتظار الإرسال • ${state.outbox.where((a) => a['status'] == 'failed').length} تعذّر إرساله',
                  ),
                  subtitle: const Text(
                    'افتح «طلباتي للتاجر» لقراءة الرد أو إعادة الإرسال.',
                  ),
                ),
              if (state.updatedAt != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule_rounded),
                  title: Text(
                    state.isCached
                        ? 'بيانات محفوظة على الجهاز'
                        : 'آخر تحديث للبيانات',
                  ),
                  subtitle: Text(
                    DateFormat(
                      'yyyy/MM/dd  HH:mm',
                    ).format(DateTime.parse(state.updatedAt!).toLocal()),
                  ),
                ),
              if (progress?.state == SyncState.error &&
                  progress?.lastMessage != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.sync_problem_rounded,
                    color: AppColors.error,
                  ),
                  title: const Text('تعذرت المزامنة'),
                  subtitle: Text(progress!.lastMessage!),
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _refreshCustomerAccounts();
                },
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('تحديث حساباتي المرتبطة'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(CustomerHomeState state, AuthState authState) {
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
          const SizedBox(height: 20),
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
              foregroundColor: AppColors.white,
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
          const SizedBox(height: 20),
          const SizedBox(height: 60),
          if (state.phoneLinkError != null || state.errorMessage != null) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.warningLight,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: AppColors.warning.withValues(alpha: 0.3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    state.requiresPhoneVerification
                        ? 'يلزم التحقق من رقم الهاتف لربط حساباتك'
                        : 'تعذر تحديث حساباتك المرتبطة',
                    style: AppTypography.titleSmall(
                      color: AppColors.textPrimary,
                    ),
                    textAlign: TextAlign.right,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    state.phoneLinkError ?? state.errorMessage!,
                    style: AppTypography.bodySmall(
                      color: AppColors.textSecondary,
                    ),
                    textAlign: TextAlign.right,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: state.isLoading
                          ? null
                          : () => ref
                                .read(customerControllerProvider.notifier)
                                .load(force: true),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('إعادة المحاولة'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
          ],
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
            'بعد التحقق من رقمك، راجع طلبات البقالات أدناه. تظهر حساباتك بعد قبول الربط؛ الربط يتيح عرض العمليات المسجلة والاعتراض عليها.',
            style: AppTypography.bodySmall(color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
        ],
      );
    }

    // 4. المحتوى الحقيقي
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (_selectedTab == 0)
          CustomerBalanceOverview(summaries: state.summaries),
        if (state.isCached || state.errorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Material(
              color: AppColors.warningLight,
              borderRadius: BorderRadius.circular(12),
              child: ListTile(
                dense: true,
                leading: const Icon(
                  Icons.cloud_off_outlined,
                  size: 20,
                  color: AppColors.warningStrong,
                ),
                title: Text(
                  state.errorMessage != null
                      ? 'تعذر التحديث؛ نعرض آخر بيانات محفوظة'
                      : 'تعرض الآن بيانات محفوظة على الجهاز',
                  style: AppTypography.caption(color: AppColors.textPrimary),
                ),
                trailing: IconButton(
                  tooltip: 'إعادة المحاولة',
                  onPressed: state.isLoading ? null : _refreshCustomerAccounts,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ),
            ),
          ),
        if (_selectedTab == 0) ...[
          _buildHomeShortcuts(state),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: _accountAction(
              icon: Icons.forum_outlined,
              title: 'طلباتي للتاجر',
              subtitle: 'عرض الرد على مشكلة في عملية',
              onTap: _openMyDisputes,
            ),
          ),
          if (authState.userId != null)
            CustomerOfflineCoverage(owner: authState.userId!),
          if (state.linkRequests.isNotEmpty) _buildLinkRequestsSection(state),
          _buildHomeBusinesses(state),
        ] else if (_selectedTab == 1) ...[
          _buildSectionIntro(
            icon: Icons.storefront_outlined,
            title: 'بقالاتي',
            subtitle: 'حساباتك المرتبطة وكشوف الحركات لكل متجر',
          ),
          _buildBusinessesSection(state),
        ] else if (_selectedTab == 2) ...[
          _buildSectionIntro(
            icon: Icons.fact_check_outlined,
            title: 'العمليات المسجلة',
            subtitle:
                'العمليات مسجلة مباشرة، ويمكنك الاعتراض من تفاصيل أي عملية',
          ),
          _buildPendingEntriesSection(state),
        ] else ...[
          _buildAccountSection(authState),
        ],
      ],
    );
  }

  void _openMyDisputes() => Navigator.of(
    context,
  ).push(AppRoutes.accountPage(builder: (_) => const CustomerDisputesScreen()));

  Widget _buildSectionIntro({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTypography.titleMedium(
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: AppTypography.caption(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeShortcuts(CustomerHomeState state) {
    final shops = state.summaries.map((s) => s.businessId).toSet().length;
    final pending = state.pendingEntries.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: _shortcutCard(
              icon: Icons.storefront_outlined,
              title: 'بقالاتي',
              value: '$shops متجر',
              onTap: () => setState(() => _selectedTab = 1),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _shortcutCard(
              icon: Icons.fact_check_outlined,
              title: 'عملياتك',
              value: '$pending قيد',
              onTap: () => setState(() => _selectedTab = 2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _shortcutCard({
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
  }) {
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.borderLight),
          ),
          child: Row(
            children: [
              Icon(icon, color: AppColors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTypography.caption(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      value,
                      style: AppTypography.titleSmall(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_left_rounded,
                color: AppColors.textMuted,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHomeBusinesses(CustomerHomeState state) {
    final summaries = state.summaries.take(2).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'حساباتك المرتبطة',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              if (state.summaries.length > 2)
                TextButton(
                  onPressed: () => setState(() => _selectedTab = 1),
                  child: const Text('عرض الكل'),
                ),
            ],
          ),
        ),
        if (summaries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _emptyPanel(
              Icons.storefront_outlined,
              'لا توجد بقالات مرتبطة بعد',
              'عند ربط حسابك بمتجر سيظهر ملخصه هنا.',
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                for (final summary in summaries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _buildBusinessCard(state, summary),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildPendingEntriesSection(CustomerHomeState state) {
    final entries = state.pendingEntries;
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
        child: _emptyPanel(
          Icons.verified_outlined,
          'لا توجد عمليات جديدة',
          'تظهر عمليات التاجر في الكشف مباشرة، ويمكنك الاعتراض عليها لاحقًا.',
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        children: [
          for (final entry in entries)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.borderLight),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color:
                              (entry.direction == 'debit'
                                      ? AppColors.debtRed
                                      : AppColors.paymentGreen)
                                  .withValues(alpha: .1),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(
                          entry.direction == 'debit'
                              ? AppIcons.debt
                              : AppIcons.payment,
                          color: entry.direction == 'debit'
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
                              entry.description.isEmpty
                                  ? (entry.direction == 'debit'
                                        ? 'قيد دين'
                                        : 'دفعة سداد')
                                  : entry.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.titleSmall(
                                color: AppColors.textPrimary,
                              ),
                            ),
                            Text(
                              _relativeTime(entry.occurredAt),
                              style: AppTypography.caption(
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${currencyFormatter.format(entry.amount)} ${_currencySymbol(entry.currencyCode)}',
                        style: AppTypography.titleSmall(
                          color: entry.direction == 'debit'
                              ? AppColors.debtRed
                              : AppColors.paymentGreen,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busyActions.contains(entry.id)
                              ? null
                              : () => _openDispute(entry),
                          child: const Text('اعتراض'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: _busyActions.contains(entry.id)
                              ? null
                              : () => _openEntry(entry),
                          child: _busyActions.contains(entry.id)
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('تفاصيل العملية'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAccountSection(AuthState authState) {
    final name = authState.displayName?.trim().isNotEmpty == true
        ? authState.displayName!.trim()
        : 'حساب العميل';
    final phone = authState.phoneNumber ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: AppColors.primaryLight,
                  child: const Icon(
                    Icons.person_rounded,
                    color: AppColors.primary,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'حساب عميل',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  name,
                  style: AppTypography.titleMedium(
                    color: AppColors.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (phone.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    phone,
                    textDirection: ui.TextDirection.ltr,
                    style: AppTypography.bodySmall(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          _accountAction(
            icon: Icons.forum_outlined,
            title: 'طلباتي للتاجر',
            subtitle: 'عرض رد التاجر على مشكلتك',
            onTap: _openMyDisputes,
          ),
          _accountAction(
            icon: Icons.dashboard_customize_outlined,
            title: 'مساحات العمل',
            subtitle: 'التبديل بين حساب العميل والتاجر',
            onTap: () => Navigator.pushNamed(context, AppRoutes.workspaces),
          ),
          _accountAction(
            icon: Icons.phonelink_lock_outlined,
            title: 'قفل التطبيق',
            subtitle: 'إدارة حماية التطبيق',
            onTap: () =>
                Navigator.pushNamed(context, AppRoutes.appLockSettings),
          ),
          _accountAction(
            icon: Icons.notifications_active_outlined,
            title: 'الإشعارات والتنبيهات',
            subtitle: 'اختيار التنبيهات التي تصلك',
            onTap: () => Navigator.of(context).push(
              AppRoutes.accountPage(
                builder: (_) => const NotificationSettingsScreen(),
              ),
            ),
          ),
          _accountAction(
            icon: Icons.lock_reset_rounded,
            title: 'تغيير كلمة المرور',
            subtitle: 'تحديث كلمة مرور حسابك',
            onTap: () => Navigator.pushNamed(context, AppRoutes.resetPassword),
          ),
          _accountAction(
            icon: Icons.logout_rounded,
            title: 'تسجيل الخروج',
            subtitle: 'الخروج من الحساب الحالي',
            destructive: true,
            onTap: () => confirmAccountSignOut(context, ref),
          ),
        ],
      ),
    );
  }

  Widget _accountAction({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool destructive = false,
  }) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    decoration: BoxDecoration(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.borderLight),
    ),
    child: ListTile(
      onTap: onTap,
      leading: Icon(
        icon,
        color: destructive ? AppColors.error : AppColors.primary,
      ),
      title: Text(
        title,
        style: AppTypography.titleSmall(
          color: destructive ? AppColors.error : AppColors.textPrimary,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: AppTypography.caption(color: AppColors.textSecondary),
      ),
      trailing: const Icon(Icons.chevron_left_rounded),
    ),
  );

  Widget _emptyPanel(IconData icon, String title, String subtitle) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: AppColors.borderLight),
    ),
    child: Column(
      children: [
        Icon(icon, size: 34, color: AppColors.primary),
        const SizedBox(height: 10),
        Text(
          title,
          style: AppTypography.titleSmall(color: AppColors.textPrimary),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: AppTypography.caption(color: AppColors.textSecondary),
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );

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
                              'ترغب «${request.businessName}»${request.businessCity != null ? ' (${request.businessCity})' : ''} بربط حسابك لعرض الحركات والديون. الربط لا يعني الإقرار بصحة العمليات.',
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
                            foregroundColor: AppColors.white,
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
    final visible = state.summaries
        .where(
          (s) => s.businessName.toLowerCase().contains(
            _businessSearch.trim().toLowerCase(),
          ),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'بقالاتي',
                style: AppTypography.titleMedium(color: AppColors.textPrimary),
              ),
              Text(
                state.summaries.isEmpty
                    ? 'لا يوجد'
                    : '${state.summaries.map((s) => s.businessId).toSet().length} بقالات',
                style: AppTypography.caption(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (state.summaries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'ابحث باسم البقالة',
                prefixIcon: Icon(Icons.search),
                filled: true,
                fillColor: AppColors.white,
              ),
              onChanged: (value) => setState(() => _businessSearch = value),
            ),
          ),
        if (state.summaries.isNotEmpty && visible.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('لا توجد بقالة مطابقة للبحث'),
          ),
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
              children: visible
                  .map(
                    (summary) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
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

    final balanceColor = isZero
        ? AppColors.textPrimary
        : owedOnCustomer
        ? AppColors.debtRed
        : AppColors.paymentGreen;
    void openLedger() => Navigator.push(
      context,
      AppRoutes.accountPage(
        builder: (_) => CustomerAccountLedgerScreen(summary: summary),
      ),
    );
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: openLedger,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: AppColors.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      AppIcons.store,
                      size: 20,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          summary.businessName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _relativeTime(summary.lastEntryAt),
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 112,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerEnd,
                          child: Text(
                            '\u2066${currencyFormatter.format(balance.abs())}\u2069 ${_currencySymbol(summary.currencyCode)}',
                            maxLines: 1,
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: balanceColor,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isZero
                              ? 'خالص'
                              : owedOnCustomer
                              ? 'عليك'
                              : 'لك',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 18,
                    child: Icon(
                      Icons.chevron_left_rounded,
                      size: 18,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
              if (pendingCount > 0) ...[
                const Divider(height: 16, color: AppColors.borderLight),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => _openPendingEntriesSheet(
                      state,
                      businessCustomerId: summary.businessCustomerId,
                    ),
                    icon: const Icon(Icons.fact_check_outlined, size: 18),
                    label: const Text('عرض العمليات المسجلة'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
