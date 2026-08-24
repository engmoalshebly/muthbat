import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/finance/currency_info.dart';
import '../../../../shared/widgets/muthbat_bottom_nav.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import '../../data/models/business_customer_model.dart';
import '../controllers/merchant_controller.dart';
import '../widgets/create_ledger_entry_sheet.dart';
import 'add_customer_screen.dart';

/// الواجهة الرئيسية الاحترافية للتاجر — تصميم عصري فائق الجمال والنعومة
class MerchantHomeScreen extends ConsumerStatefulWidget {
  final int initialTab;

  const MerchantHomeScreen({super.key, this.initialTab = 0});

  @override
  ConsumerState<MerchantHomeScreen> createState() => _MerchantHomeScreenState();
}

class _MerchantHomeScreenState extends ConsumerState<MerchantHomeScreen> {
  int _currentTab = 0; // 0=الرئيسية, 1=العملاء, 2=التقارير, 3=الملف
  int _currentBannerPage = 0;
  int _currentCurrencyPage = 0;

  final TextEditingController _searchController = TextEditingController();
  late final PageController _bannerController;
  late final PageController _currencyCardController;
  Timer? _bannerTimer;
  StreamSubscription<SyncProgress>? _syncProgressSubscription;
  bool _manualSyncInProgress = false;
  int _analyticsDays = 30;
  String? _analyticsCurrency;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _currentTab = widget.initialTab.clamp(0, 3).toInt();
  }

  @override
  void initState() {
    super.initState();
    _bannerController = PageController();
    _currencyCardController = PageController();
    _startBannerAutoScroll();
    _syncProgressSubscription = SyncEngine.instance.progressStream.listen((
      progress,
    ) {
      if (!mounted ||
          progress.state != SyncState.synced ||
          _manualSyncInProgress) {
        return;
      }
      ref.read(merchantControllerProvider.notifier).loadDashboard();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(merchantControllerProvider.notifier).loadDashboard();
    });
  }

  void _startBannerAutoScroll() {
    _bannerTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || !_bannerController.hasClients) return;
      final next = (_currentBannerPage + 1) % 4;
      _bannerController.animateToPage(
        next,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _syncProgressSubscription?.cancel();
    _bannerController.dispose();
    _currencyCardController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openAddCustomer() async {
    final customer = await showDialog<BusinessCustomerModel>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const AddCustomerScreen(),
    );
    if (!mounted || customer == null) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('تمت إضافة العميل «${customer.localDisplayName}» بنجاح'),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );

    await Navigator.of(
      context,
    ).pushNamed(AppRoutes.customerLedger, arguments: customer);
  }

  /// فتح قيد دين أو سداد بعد اختيار العميل من القائمة دائماً.
  void _openCreateEntry({required String type}) {
    final customers = ref.read(merchantControllerProvider).customers;
    if (customers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.info_outline, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Expanded(
                child: Text('يرجى إضافة أول عميل قبل تسجيل العمليات المالية'),
              ),
            ],
          ),
          backgroundColor: AppColors.primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          action: SnackBarAction(
            label: 'إضافة عميل',
            textColor: AppColors.accentGold,
            onPressed: _openAddCustomer,
          ),
        ),
      );
      _openAddCustomer();
      return;
    }

    // إظهار قائمة العملاء حتى عند وجود عميل واحد يجعل مسار العمليات ثابتاً
    // ويمنع تسجيل القيد على عميل غير مقصود.
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _CustomerPickerSheet(
        customers: customers,
        actionTitle: type == 'debt'
            ? 'تسجيل دين جديد على العميل'
            : 'تسجيل سداد / دفعة من العميل',
        onSelected: (customer) {
          Navigator.pop(ctx);
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) =>
                CreateLedgerEntrySheet(customer: customer, initialType: type),
          ).then((_) {
            if (mounted) {
              ref.read(merchantControllerProvider.notifier).loadDashboard();
            }
          });
        },
      ),
    );
  }

  Future<void> _runManualSync() async {
    if (_manualSyncInProgress) return;

    // تحديث الواجهة فورًا حتى يرى المستخدم أن الطلب بدأ قبل عودة الشبكة.
    setState(() => _manualSyncInProgress = true);
    final controller = ref.read(merchantControllerProvider.notifier);
    try {
      await controller.syncNow();
      if (!mounted) return;

      final error = ref.read(merchantControllerProvider).lastError;
      if (error != null && error.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _manualSyncInProgress = false);
      }
    }
  }

  void _openNotifications() {
    final dashboard = ref.read(merchantControllerProvider);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StreamBuilder<SyncProgress>(
          stream: SyncEngine.instance.progressStream,
          builder: (context, snapshot) {
            final progress = snapshot.data;
            final hasDisputes = dashboard.openDisputesCount > 0;
            final hasPendingSync = (progress?.pendingCount ?? 0) > 0;

            return Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              decoration: const BoxDecoration(
                color: AppColors.surfaceLight,
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
                        color: AppColors.borderMedium,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'التنبيهات',
                    style: AppTypography.titleLarge(
                      color: AppColors.textPrimary,
                    ),
                    textAlign: TextAlign.right,
                  ),
                  const SizedBox(height: 12),
                  if (!hasDisputes && !hasPendingSync)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Column(
                        children: [
                          Icon(
                            AppIcons.notifications,
                            size: 42,
                            color: AppColors.textMuted.withValues(alpha: 0.7),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'لا توجد تنبيهات جديدة',
                            style: AppTypography.bodyLarge(
                              color: AppColors.textSecondary,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  if (hasDisputes)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(
                        backgroundColor: AppColors.errorLight,
                        foregroundColor: AppColors.error,
                        child: Icon(AppIcons.dispute),
                      ),
                      title: Text(
                        'اعتراضات تحتاج مراجعة',
                        style: AppTypography.titleSmall(
                          color: AppColors.textPrimary,
                        ),
                      ),
                      subtitle: Text(
                        '${dashboard.openDisputesCount} اعتراض مفتوح',
                        style: AppTypography.bodySmall(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      trailing: const Icon(
                        AppIcons.chevronEnd,
                        color: AppColors.textMuted,
                      ),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        Navigator.pushNamed(context, AppRoutes.disputesList);
                      },
                    ),
                  if (hasPendingSync)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(
                        backgroundColor: AppColors.warningLight,
                        foregroundColor: AppColors.warning,
                        child: Icon(AppIcons.sync),
                      ),
                      title: Text(
                        'بيانات بانتظار المزامنة',
                        style: AppTypography.titleSmall(
                          color: AppColors.textPrimary,
                        ),
                      ),
                      subtitle: Text(
                        '${progress!.pendingCount} عملية لم ترفع بعد',
                        style: AppTypography.bodySmall(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      trailing: const Icon(
                        AppIcons.chevronEnd,
                        color: AppColors.textMuted,
                      ),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _runManualSync();
                      },
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: IndexedStack(
        index: _currentTab,
        children: [
          _buildHomeTab(),
          _buildCustomersTab(),
          _buildReportsTab(),
          _buildProfileTab(),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  // =============================================
  //  شريط التنقل السفلي (Bottom Navigation Bar)
  // =============================================
  Widget _buildBottomNav() {
    return MuthbatBottomNav(
      currentIndex: _currentTab,
      items: const [
        MuthbatNavItem(icon: AppIcons.home, label: 'الرئيسية'),
        MuthbatNavItem(icon: AppIcons.customers, label: 'العملاء'),
        MuthbatNavItem(icon: AppIcons.reports, label: 'التقارير'),
        MuthbatNavItem(icon: AppIcons.profile, label: 'الملف'),
      ],
      onTap: (index) {
        if (index == 3) {
          Navigator.pushNamed(context, AppRoutes.merchantProfile);
          return;
        }
        setState(() => _currentTab = index);
      },
    );
  }

  // =============================================
  //  تبويب الرئيسية (Home Tab) — التصميم المبتكر الفاخر
  // =============================================
  Widget _buildHomeTab() {
    final state = ref.watch(merchantControllerProvider);
    final authState = ref.watch(authControllerProvider);
    final currencyFormatter = NumberFormat('#,##0', 'ar');
    final userName = authState.displayName ?? 'التاجر';

    // تحية زمنية
    final hour = DateTime.now().hour;
    String greeting = hour < 12
        ? 'صباح الخير'
        : (hour < 17 ? 'مساء النور' : 'مساء الخير');

    return RefreshIndicator(
      onRefresh: () => ref.read(merchantControllerProvider.notifier).syncNow(),
      color: AppColors.primary,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- 1. الترويسة العلوية الأنيقة ---
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$greeting، $userName',
                            style:
                                AppTypography.titleLarge(
                                  color: AppColors.textPrimary,
                                ).copyWith(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 19,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            state.businessName,
                            style: AppTypography.bodySmall(
                              color: AppColors.textSecondary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),

                    // زر المزامنة الذكية
                    StreamBuilder<SyncProgress>(
                      stream: SyncEngine.instance.progressStream,
                      builder: (context, snapshot) {
                        final progress = snapshot.data;
                        final isSyncing =
                            _manualSyncInProgress ||
                            progress?.state == SyncState.syncing;
                        final pending = progress?.pendingCount ?? 0;

                        return Stack(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(9),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppColors.borderLight,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.02),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                              child: isSyncing
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: AppColors.secondary,
                                      ),
                                    )
                                  : GestureDetector(
                                      onTap: _runManualSync,
                                      child: const Icon(
                                        Icons.sync_rounded,
                                        size: 18,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                            ),
                            if (pending > 0)
                              Positioned(
                                right: 0,
                                top: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: const BoxDecoration(
                                    color: AppColors.debtRed,
                                    shape: BoxShape.circle,
                                  ),
                                  constraints: const BoxConstraints(
                                    minWidth: 15,
                                    minHeight: 15,
                                  ),
                                  child: Text(
                                    '$pending',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 8,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(width: 8),

                    // زر الإشعارات / النزاعات
                    Stack(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(9),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(color: AppColors.borderLight),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.02),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                          child: InkWell(
                            onTap: _openNotifications,
                            customBorder: const CircleBorder(),
                            child: const Padding(
                              padding: EdgeInsets.all(3),
                              child: Icon(
                                Icons.notifications_outlined,
                                size: 18,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                        if (state.openDisputesCount > 0)
                          Positioned(
                            right: 2,
                            top: 2,
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(
                                color: AppColors.debtRed,
                                shape: BoxShape.circle,
                              ),
                              constraints: const BoxConstraints(
                                minWidth: 15,
                                minHeight: 15,
                              ),
                              child: Text(
                                '${state.openDisputesCount}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 8,
                                  fontWeight: FontWeight.bold,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ).animate().fadeIn(duration: 300.ms),

            const SizedBox(height: 10),

            // --- 2. كاروسيل الأرصدة متعددة العملات الفاخر (3 كروت: يمني، سعودي، دولار مع التمرير) ---
            _buildMultiCurrencyHeroCarousel(state)
                .animate()
                .fadeIn(delay: 100.ms, duration: 400.ms)
                .slideY(begin: 0.06, end: 0),

            const SizedBox(height: 12),

            // --- 3. كاروسيل الإعلانات المدمج (خلفية بيضاء مع تدرج ناعم بالأخير) ---
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Column(
                children: [
                  SizedBox(
                    height: 68,
                    child: PageView(
                      controller: _bannerController,
                      onPageChanged: (index) =>
                          setState(() => _currentBannerPage = index),
                      children: [
                        _buildLuxeBannerSlide(
                          accentColor: AppColors.secondary,
                          icon: AppIcons.whatsapp,
                          title: 'توثيق السندات عبر واتساب',
                          subtitle:
                              'إرسال فوري لكشوفات الحساب وإشعارات السندات بروابط رسمية.',
                          badge: 'جديد 📲',
                          onTap: _openAddCustomer,
                        ),
                        _buildLuxeBannerSlide(
                          accentColor: AppColors.primary,
                          icon: AppIcons.shieldCheck,
                          title: 'سندات موثقة وغير قابلة للإنكار',
                          subtitle:
                              'حماية كاملة لحقوقك المالية مع توثيق إلكتروني معتمد بالوقت.',
                          badge: 'أمان 🛡️',
                          onTap: () => setState(() => _currentTab = 1),
                        ),
                        _buildLuxeBannerSlide(
                          accentColor: AppColors.secondaryDark,
                          icon: AppIcons.team,
                          title: 'إدارة صلاحيات فريق العمل',
                          subtitle:
                              'أضف المحاسبين والموظفين وحدد صلاحياتهم بدقة متناهية.',
                          badge: 'فريق 👥',
                          onTap: () =>
                              Navigator.pushNamed(context, AppRoutes.team),
                        ),
                        _buildLuxeBannerSlide(
                          accentColor: AppColors.accentGoldDark,
                          icon: AppIcons.reports,
                          title: 'تقارير التحصيل والديون الفورية',
                          subtitle:
                              'تابع أداء السيولة ونسب السداد ببيانات ورسوم بيانية ذكية.',
                          badge: 'تقارير 📊',
                          onTap: () => setState(() => _currentTab = 2),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  // مؤشرات الكاروسيل الناعمة
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(4, (i) {
                      final isActive = _currentBannerPage == i;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 280),
                        margin: const EdgeInsets.symmetric(horizontal: 2.5),
                        width: isActive ? 16 : 5,
                        height: 4,
                        decoration: BoxDecoration(
                          color: isActive
                              ? AppColors.primary
                              : AppColors.borderLight,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      );
                    }),
                  ),
                ],
              ),
            ).animate().fadeIn(delay: 150.ms, duration: 400.ms),

            const SizedBox(height: 18),

            // --- 4. عنوان قسم العمليات السريعة ---
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 16,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'العمليات والخدمات',
                    style: AppTypography.titleMedium(
                      color: AppColors.textPrimary,
                    ).copyWith(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),

            // --- 5. الإجراءات المالية الرئيسية (بطاقتي تسجيل دين وتسجيل سداد البارزة) ---
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  // بطاقة تسجيل دَين الكبيرة
                  Expanded(
                    child: _buildPrimaryActionCard(
                      title: 'تسجيل دَين',
                      subtitle: 'إضافة قيد ذمة',
                      tag: '+ دَين جديد',
                      icon: AppIcons.debt,
                      bgGradient: LinearGradient(
                        begin: Alignment.topRight,
                        colors: [
                          AppColors.debtRed.withValues(alpha: 0.06),
                          AppColors.debtRed.withValues(alpha: 0.04),
                        ],
                      ),
                      borderColor: AppColors.debtRed.withValues(alpha: 0.2),
                      accentColor: AppColors.debtRed,
                      onTap: () => _openCreateEntry(type: 'debt'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // بطاقة تسجيل سداد الكبيرة
                  Expanded(
                    child: _buildPrimaryActionCard(
                      title: 'تسجيل سداد',
                      subtitle: 'توثيق دفعة مالية',
                      tag: '✓ قبض دفعة',
                      icon: AppIcons.payment,
                      bgGradient: LinearGradient(
                        begin: Alignment.topRight,
                        end: Alignment.bottomLeft,
                        colors: [
                          AppColors.paymentGreen.withValues(alpha: 0.06),
                          AppColors.paymentGreen.withValues(alpha: 0.04),
                        ],
                      ),
                      borderColor: AppColors.paymentGreen.withValues(
                        alpha: 0.2,
                      ),
                      accentColor: AppColors.paymentGreen,
                      onTap: () => _openCreateEntry(type: 'payment'),
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(delay: 200.ms, duration: 400.ms),

            const SizedBox(height: 10),

            // --- 6. شبكة الأدوات الإدارية الذكية (4 بطاقات 2×2 عصرية) ---
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Expanded(
                    child: _buildSecondaryToolCard(
                      title: 'عميل جديد',
                      subtitle: 'فتح حساب زبون',
                      icon: AppIcons.customers,
                      accentColor: AppColors.secondary,
                      bgColor: AppColors.secondary.withValues(alpha: 0.08),
                      borderColor: AppColors.secondary.withValues(alpha: 0.2),
                      onTap: _openAddCustomer,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildSecondaryToolCard(
                      title: 'كشف حساب',
                      subtitle: 'تصدير ومشاركة',
                      icon: AppIcons.statement,
                      accentColor: AppColors.primary,
                      bgColor: AppColors.primary.withValues(alpha: 0.08),
                      borderColor: AppColors.primary.withValues(alpha: 0.2),
                      onTap: () => setState(() => _currentTab = 1),
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(delay: 250.ms, duration: 400.ms),

            const SizedBox(height: 10),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Expanded(
                    child: _buildSecondaryToolCard(
                      title: 'النزاعات والطلبات',
                      subtitle: 'الاعتراضات المباشرة',
                      icon: AppIcons.dispute,
                      accentColor: AppColors.warning,
                      bgColor: AppColors.warningLight,
                      borderColor: AppColors.warning.withValues(alpha: 0.2),
                      badge: state.openDisputesCount > 0
                          ? '${state.openDisputesCount}'
                          : null,
                      onTap: () =>
                          Navigator.pushNamed(context, AppRoutes.disputesList),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildSecondaryToolCard(
                      title: 'إدارة الفريق',
                      subtitle: 'الموظفين والصلاحيات',
                      icon: AppIcons.team,
                      accentColor: AppColors.secondaryDark,
                      bgColor: AppColors.secondaryDark.withValues(alpha: 0.08),
                      borderColor: AppColors.secondaryDark.withValues(
                        alpha: 0.2,
                      ),
                      onTap: () => Navigator.pushNamed(context, AppRoutes.team),
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(delay: 300.ms, duration: 400.ms),

            const SizedBox(height: 22),

            // --- 7. آخر القيود المالية الفعلية ---
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 16,
                    decoration: BoxDecoration(
                      color: AppColors.secondary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'العمليات الأخيرة',
                    style: AppTypography.titleMedium(
                      color: AppColors.textPrimary,
                    ).copyWith(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() => _currentTab = 1),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: const Size(0, 30),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'كل العملاء (${state.customers.length})',
                          style: AppTypography.bodySmall(
                            color: AppColors.secondary,
                          ).copyWith(fontWeight: FontWeight.w800, fontSize: 12),
                        ),
                        const Icon(
                          AppIcons.chevronEnd,
                          size: 16,
                          color: AppColors.secondary,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 6),

            // قائمة القيود: دين، سداد، خصم، عكس...
            _buildRecentOperationsList(),

            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }

  /// كاروسيل الأرصدة متعددة العملات الفاخر (3 كروت للعملات: ريال يمني، ريال سعودي، دولار أمريكي)
  Widget _buildMultiCurrencyHeroCarousel(MerchantDashboardState state) {
    final currencyFormatter = NumberFormat('#,##0.##', 'ar');
    final breakdown = state.currencyBreakdown;

    final List<Map<String, dynamic>> currencies = [];
    for (final code in state.supportedCurrencies.map(
      (value) => value.toUpperCase(),
    )) {
      final info = CurrencyCatalog.forCode(code, state.currencies);
      final values = breakdown[code] ?? const <String, double>{};
      currencies.add({
        'code': code,
        'title': info.name,
        'flag': '💱',
        'symbol': info.symbol,
        'gradient': AppColors.brandGradient,
        'accentColor': AppColors.accentGold,
        'receivables': values['receivables'] ?? 0.0,
        'payables': values['payables'] ?? 0.0,
        'customerCount': (values['customers'] ?? 0.0).toInt(),
      });
    }

    return Column(
      children: [
        // سلايدر كروت العملات (تمرير أفقي سلس بين العملات)
        SizedBox(
          height: 168,
          child: PageView.builder(
            controller: _currencyCardController,
            itemCount: currencies.length,
            onPageChanged: (i) => setState(() => _currentCurrencyPage = i),
            itemBuilder: (ctx, index) {
              final c = currencies[index];
              final receivables = c['receivables'] as double;
              final payables = c['payables'] as double;
              final custCount = c['customerCount'] as int;

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  decoration: BoxDecoration(
                    gradient: c['gradient'] as Gradient,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                      width: 1.1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (c['gradient'] as LinearGradient).colors.first
                            .withValues(alpha: 0.28),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // الصف العلوي
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: (c['accentColor'] as Color).withValues(
                                alpha: 0.2,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              Icons.account_balance_wallet_rounded,
                              color: c['accentColor'] as Color,
                              size: 15,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${c['flag']} ${c['title']}',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.95),
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2.5,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Text(
                              custCount > 0 ? '$custCount عميل' : 'لا توجد ذمم',
                              style: TextStyle(
                                color: c['accentColor'] as Color,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),

                      // المبلغ الإجمالي للديون
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            currencyFormatter.format(receivables),
                            style: AppTypography.financialAmount(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            c['symbol'] as String,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            'إجمالي ما لك (ديون)',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.65),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),

                      // الصف المالي الفرعي (لك / عليك)
                      Row(
                        children: [
                          // لك
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6.5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(11),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.06),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(3.5),
                                    decoration: BoxDecoration(
                                      color: AppColors.accentGold.withValues(
                                        alpha: 0.25,
                                      ),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    child: const Icon(
                                      Icons.arrow_upward_rounded,
                                      color: AppColors.accentGold,
                                      size: 11,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'لك (ديون)',
                                          style: TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: 0.6,
                                            ),
                                            fontSize: 9,
                                          ),
                                        ),
                                        Text(
                                          '${currencyFormatter.format(receivables)} ${c['symbol']}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w800,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),

                          // عليك
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6.5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(11),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.06),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(3.5),
                                    decoration: BoxDecoration(
                                      color: AppColors.paymentGreen.withValues(
                                        alpha: 0.25,
                                      ),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    child: const Icon(
                                      Icons.arrow_downward_rounded,
                                      color: AppColors.paymentGreen,
                                      size: 11,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'عليك (مقدّم)',
                                          style: TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: 0.6,
                                            ),
                                            fontSize: 9,
                                          ),
                                        ),
                                        Text(
                                          '${currencyFormatter.format(payables)} ${c['symbol']}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w800,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 6),

        // مؤشرات الكاروسيل
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(currencies.length, (i) {
            final isActive = _currentCurrencyPage == i;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 280),
              margin: const EdgeInsets.symmetric(horizontal: 2.5),
              width: isActive ? 16 : 5,
              height: 4,
              decoration: BoxDecoration(
                color: isActive ? AppColors.primary : AppColors.borderLight,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        ),
      ],
    );
  }

  /// شريحة إعلانية مدمجة — خلفية بيضاء مع تدرج لوني ناعم بالأخير
  Widget _buildLuxeBannerSlide({
    required Color accentColor,
    required IconData icon,
    required String title,
    required String subtitle,
    required String badge,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerRight,
          end: Alignment.centerLeft,
          colors: [
            Colors.white,
            Colors.white,
            accentColor.withValues(alpha: 0.14),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderLight, width: 1.1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.025),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          splashColor: accentColor.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                // أيقونة البنر
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, color: accentColor, size: 19),
                ),
                const SizedBox(width: 10),

                // نصوص الإعلان
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: accentColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              badge,
                              style: TextStyle(
                                color: accentColor,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: AppColors.textSecondary,
                          height: 1.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.arrow_back_ios_new_rounded,
                  size: 12,
                  color: accentColor.withValues(alpha: 0.7),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// بطاقة الإجراء المالي الرئيسي البارز (تسجيل دين / سداد)
  Widget _buildPrimaryActionCard({
    required String title,
    required String subtitle,
    required String tag,
    required IconData icon,
    required Gradient bgGradient,
    required Color borderColor,
    required Color accentColor,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        gradient: bgGradient,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: accentColor.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          splashColor: accentColor.withValues(alpha: 0.12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: accentColor,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: accentColor.withValues(alpha: 0.35),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Icon(icon, color: Colors.white, size: 18),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: accentColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: accentColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: accentColor.withValues(alpha: 0.7),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// بطاقة الأداة الإدارية الذكية (عميل، كشف حساب، نزاعات، فريق)
  Widget _buildSecondaryToolCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
    required Color bgColor,
    required Color borderColor,
    required VoidCallback onTap,
    String? badge,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderLight, width: 1.1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          splashColor: accentColor.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: bgColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: borderColor),
                      ),
                      child: Icon(icon, color: accentColor, size: 20),
                    ),
                    if (badge != null)
                      Positioned(
                        top: -4,
                        left: -4,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: AppColors.debtRed,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 14,
                            minHeight: 14,
                          ),
                          child: Text(
                            badge,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecentOperationsList() {
    final state = ref.watch(merchantControllerProvider);
    final entries = state.recentEntries;
    final customersById = {
      for (final customer in state.customers) customer.id: customer,
    };

    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.borderLight),
          ),
          child: const Column(
            children: [
              Icon(
                Icons.receipt_long_outlined,
                color: AppColors.textMuted,
                size: 30,
              ),
              SizedBox(height: 8),
              Text(
                'لا توجد عمليات مالية بعد',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'ستظهر هنا عمليات الدين والسداد والخصم فور تسجيلها.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        children: entries.map((entry) {
          final customer = customersById[entry.businessCustomerId];
          final isCredit = entry.direction == 'credit';
          final color = isCredit ? AppColors.paymentGreen : AppColors.debtRed;
          final symbol = CurrencyCatalog.forCode(entry.currencyCode).symbol;
          final amount = NumberFormat('#,##0.##', 'ar').format(entry.amount);
          final occurred = DateTime.tryParse(entry.occurredAt)?.toLocal();
          final date = occurred == null
              ? entry.occurredAt
              : DateFormat('yyyy/MM/dd - HH:mm', 'ar').format(occurred);
          final typeLabel = switch (entry.entryType) {
            'debt' => 'إضافة دين',
            'payment' => 'تسجيل سداد',
            'discount' => 'خصم للعميل',
            'fee' => 'إضافة رسوم',
            'reversal' => 'عكس عملية',
            'opening_balance' => 'رصيد افتتاحي',
            _ => 'عملية مالية',
          };
          final icon = switch (entry.entryType) {
            'payment' || 'discount' => AppIcons.payment,
            'reversal' => Icons.undo_rounded,
            _ => AppIcons.debt,
          };
          final pending = entry.syncStatus != 'synced';

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: customer == null
                    ? null
                    : () => Navigator.pushNamed(
                        context,
                        AppRoutes.customerLedger,
                        arguments: customer,
                      ),
                child: Padding(
                  padding: const EdgeInsets.all(13),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(icon, color: color, size: 20),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    typeLabel,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.textPrimary,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                if (pending)
                                  const Icon(
                                    Icons.cloud_upload_outlined,
                                    size: 15,
                                    color: AppColors.warning,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              customer?.localDisplayName ?? 'عميل غير متاح',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${entry.description.isEmpty ? 'بدون تفاصيل' : entry.description} • $date',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${isCredit ? '-' : '+'}$amount $symbol',
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w900,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            pending ? 'بانتظار المزامنة' : 'تمت المزامنة',
                            style: TextStyle(
                              color: pending
                                  ? AppColors.warning
                                  : AppColors.textMuted,
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildRecentCustomersList() {
    final state = ref.watch(merchantControllerProvider);
    final currencyFormatter = NumberFormat('#,##0', 'ar');
    final recentCustomers = state.customers.take(4).toList();

    if (recentCustomers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.borderLight),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.people_outline_rounded,
                  size: 28,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'لا يوجد عملاء مسجلين بعد',
                style: AppTypography.titleSmall(
                  color: AppColors.textPrimary,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'اضغط على «عميل جديد» لبدء توثيق الديون والدفعات فوراً',
                style: AppTypography.bodySmall(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        children: recentCustomers.map((customer) {
          final hasDebt = customer.currentBalance > 0;
          final isZero = customer.currentBalance == 0;

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.borderLight),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.02),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => Navigator.pushNamed(
                  context,
                  AppRoutes.customerLedger,
                  arguments: customer,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: hasDebt
                            ? AppColors.debtRed.withValues(alpha: 0.1)
                            : (isZero
                                  ? AppColors.borderSubtle
                                  : AppColors.paymentGreen.withValues(
                                      alpha: 0.1,
                                    )),
                        child: Text(
                          customer.localDisplayName.isNotEmpty
                              ? customer.localDisplayName[0]
                              : 'ع',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: hasDebt
                                ? AppColors.debtRed
                                : (isZero
                                      ? AppColors.textMuted
                                      : AppColors.paymentGreen),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    customer.localDisplayName,
                                    style:
                                        AppTypography.titleSmall(
                                          color: AppColors.textPrimary,
                                        ).copyWith(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (customer.linkStatus == 'linked') ...[
                                  const SizedBox(width: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.primaryLight.withValues(
                                        alpha: 0.1,
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'مربوط',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: AppColors.primary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              customer.phone ?? 'بدون رقم هاتف',
                              style: AppTypography.bodySmall(
                                color: AppColors.textMuted,
                              ).copyWith(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      _buildCustomerBalanceBlock(customer, state.currency),
                    ],
                  ),
                ),
              ),
            ),
          ).animate().fadeIn(duration: 200.ms);
        }).toList(),
      ),
    );
  }

  /// ويدجت احترافي لعرض رصيد العميل حسب كل عملة
  Widget _buildCustomerBalanceBlock(
    BusinessCustomerModel customer,
    String defaultCurrency,
  ) {
    final currencyFormatter = NumberFormat('#,##0', 'ar');
    final bals = customer.currencyBalances;

    if (bals.isEmpty) {
      final bal = customer.currentBalance;
      final isZero = bal == 0;
      final hasDebt = bal > 0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            isZero
                ? 'خالص (0.00)'
                : (hasDebt
                      ? '${currencyFormatter.format(bal)} $defaultCurrency'
                      : '${currencyFormatter.format(bal.abs())} $defaultCurrency'),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: isZero
                  ? AppColors.textMuted
                  : (hasDebt ? AppColors.debtRed : AppColors.paymentGreen),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            isZero
                ? 'لا توجد ذمم'
                : (hasDebt ? 'عليه للتاجر' : 'له دفعة مقدمة'),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: isZero
                  ? AppColors.textMuted
                  : (hasDebt ? AppColors.debtRed : AppColors.paymentGreen),
            ),
          ),
        ],
      );
    }

    final nonZeroEntries = bals.entries.where((e) => e.value != 0).toList();
    if (nonZeroEntries.isEmpty) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            'خالص (0.00)',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: AppColors.textMuted,
            ),
          ),
          SizedBox(height: 2),
          Text(
            'لا توجد ذمم',
            style: TextStyle(fontSize: 10, color: AppColors.textMuted),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: nonZeroEntries.map((entry) {
        final symbol = CurrencyCatalog.forCode(entry.key).symbol;
        final hasDebt = entry.value > 0;
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
            '${hasDebt ? "عليه" : "له"} ${currencyFormatter.format(entry.value.abs())} $symbol',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: hasDebt ? AppColors.debtRed : AppColors.paymentGreen,
            ),
          ),
        );
      }).toList(),
    );
  }

  // =============================================
  //  تبويب العملاء (Customers Tab)
  // =============================================
  Widget _buildCustomersTab() {
    final state = ref.watch(merchantControllerProvider);

    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text(
                        'سجل العملاء',
                        style: AppTypography.titleMedium(
                          color: AppColors.textPrimary,
                        ).copyWith(fontWeight: FontWeight.w800),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: _openAddCustomer,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.person_add_rounded,
                                size: 15,
                                color: Colors.white,
                              ),
                              SizedBox(width: 6),
                              Text(
                                'عميل جديد',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 48,
                    child: TextField(
                      controller: _searchController,
                      onChanged: (val) => ref
                          .read(merchantControllerProvider.notifier)
                          .search(val),
                      decoration: InputDecoration(
                        hintText: 'ابحث باسم العميل أو رقم الهاتف...',
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          color: AppColors.textSecondary,
                        ),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded),
                                onPressed: () {
                                  _searchController.clear();
                                  ref
                                      .read(merchantControllerProvider.notifier)
                                      .search('');
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: Colors.white,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(
                            color: AppColors.borderLight,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(
                            color: AppColors.borderLight,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (state.customers.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: AppColors.primaryContainer,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.people_outline_rounded,
                          size: 48,
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'لا يوجد عملاء مسجلين بعد',
                        style: AppTypography.titleMedium(
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'اضغط على زر «عميل جديد» لبدء التسجيل',
                        style: AppTypography.bodySmall(
                          color: AppColors.textSecondary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 80),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final customer = state.customers[index];
                  final hasDebt = customer.currentBalance > 0;
                  final isZero = customer.currentBalance == 0;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 9),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceLight,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: hasDebt
                            ? AppColors.debtRed.withValues(alpha: 0.18)
                            : AppColors.borderLight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.025),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(18),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => Navigator.pushNamed(
                          context,
                          AppRoutes.customerLedger,
                          arguments: customer,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(11, 10, 10, 10),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 21,
                                backgroundColor: hasDebt
                                    ? AppColors.debtRed.withValues(alpha: 0.1)
                                    : (isZero
                                          ? AppColors.borderSubtle
                                          : AppColors.paymentGreen.withValues(
                                              alpha: 0.1,
                                            )),
                                child: Text(
                                  customer.localDisplayName.isNotEmpty
                                      ? customer.localDisplayName[0]
                                      : 'ع',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: hasDebt
                                        ? AppColors.debtRed
                                        : (isZero
                                              ? AppColors.textSecondary
                                              : AppColors.paymentGreen),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      customer.localDisplayName,
                                      style:
                                          AppTypography.titleSmall(
                                            color: AppColors.textPrimary,
                                          ).copyWith(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w800,
                                          ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      customer.phone ?? 'بدون رقم هاتف',
                                      style: AppTypography.bodySmall(
                                        color: AppColors.textSecondary,
                                      ).copyWith(fontSize: 10),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: hasDebt
                                          ? AppColors.debtRed.withValues(
                                              alpha: 0.06,
                                            )
                                          : (isZero
                                                ? AppColors.backgroundLight
                                                : AppColors.paymentGreen
                                                      .withValues(alpha: 0.06)),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: _buildCustomerBalanceBlock(
                                      customer,
                                      state.currency,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      GestureDetector(
                                        onTap: () {
                                          showModalBottomSheet(
                                            context: context,
                                            isScrollControlled: true,
                                            backgroundColor: Colors.transparent,
                                            builder: (_) =>
                                                CreateLedgerEntrySheet(
                                                  customer: customer,
                                                  initialType: 'debt',
                                                ),
                                          );
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: AppColors.debtRed.withValues(
                                              alpha: 0.08,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                          child: const Text(
                                            'دين +',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: AppColors.debtRed,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      GestureDetector(
                                        onTap: () {
                                          showModalBottomSheet(
                                            context: context,
                                            isScrollControlled: true,
                                            backgroundColor: Colors.transparent,
                                            builder: (_) =>
                                                CreateLedgerEntrySheet(
                                                  customer: customer,
                                                  initialType: 'payment',
                                                ),
                                          );
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: AppColors.paymentGreen
                                                .withValues(alpha: 0.08),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                          child: const Text(
                                            'سداد -',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: AppColors.paymentGreen,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(width: 2),
                              const Icon(
                                Icons.chevron_left_rounded,
                                size: 18,
                                color: AppColors.textMuted,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ).animate().fadeIn(duration: 200.ms);
                }, childCount: state.customers.length),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildReportsTab() {
    final state = ref.watch(merchantControllerProvider);
    final currencies = state.supportedCurrencies.isEmpty
        ? [state.currencyCode]
        : state.supportedCurrencies;
    final currency = currencies.contains(_analyticsCurrency)
        ? _analyticsCurrency!
        : (currencies.contains(state.currencyCode)
              ? state.currencyCode
              : currencies.first);
    final now = DateTime.now();
    final cutoff = now.subtract(Duration(days: _analyticsDays));
    final entries = state.ledgerEntries.where((entry) {
      final date = DateTime.tryParse(entry.occurredAt)?.toLocal();
      return entry.currencyCode == currency &&
          date != null &&
          !date.isBefore(cutoff) &&
          !date.isAfter(now);
    }).toList();
    final debits = entries
        .where((entry) => entry.direction != 'credit')
        .fold<double>(0, (sum, entry) => sum + entry.amount);
    final credits = entries
        .where((entry) => entry.direction == 'credit')
        .fold<double>(0, (sum, entry) => sum + entry.amount);
    final net = debits - credits;
    final collectionRate = debits == 0 ? 0.0 : (credits / debits) * 100;
    final symbol = CurrencyCatalog.forCode(currency).symbol;
    final formatter = NumberFormat('#,##0.##', 'ar');

    final customerDebts = <BusinessCustomerModel, double>{};
    for (final customer in state.customers) {
      final balance =
          customer.currencyBalances[currency] ??
          (currency == state.currencyCode ? customer.currentBalance : 0.0);
      if (balance > 0) customerDebts[customer] = balance;
    }
    final topDebtors = customerDebts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final daily = List.generate(7, (index) {
      final day = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: 6 - index));
      double dayDebits = 0;
      double dayCredits = 0;
      for (final entry in entries) {
        final date = DateTime.tryParse(entry.occurredAt)?.toLocal();
        if (date != null &&
            date.year == day.year &&
            date.month == day.month &&
            date.day == day.day) {
          if (entry.direction == 'credit') {
            dayCredits += entry.amount;
          } else {
            dayDebits += entry.amount;
          }
        }
      }
      return (day: day, debits: dayDebits, credits: dayCredits);
    });
    final maxDaily = daily.fold<double>(
      0,
      (maxValue, item) =>
          (item.debits > item.credits ? item.debits : item.credits) > maxValue
          ? (item.debits > item.credits ? item.debits : item.credits)
          : maxValue,
    );

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () =>
            ref.read(merchantControllerProvider.notifier).loadDashboard(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
          children: [
            Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'التحليلات المالية',
                      style: AppTypography.titleLarge(
                        color: AppColors.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w900, fontSize: 21),
                    ),
                    Text(
                      'محسوبة من دفتر العمليات المحلي',
                      style: AppTypography.bodySmall(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'تحديث',
                  onPressed: () => ref
                      .read(merchantControllerProvider.notifier)
                      .loadDashboard(),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.borderLight),
              ),
              child: Column(
                children: [
                  SizedBox(
                    height: 38,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: currencies.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, index) {
                        final code = currencies[index];
                        return ChoiceChip(
                          label: Text(code),
                          selected: code == currency,
                          onSelected: (_) =>
                              setState(() => _analyticsCurrency = code),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 7, label: Text('7 أيام')),
                      ButtonSegment(value: 30, label: Text('30 يوماً')),
                      ButtonSegment(value: 365, label: Text('سنة')),
                    ],
                    selected: {_analyticsDays},
                    onSelectionChanged: (value) =>
                        setState(() => _analyticsDays = value.first),
                    showSelectedIcon: false,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.55,
              children: [
                _analyticsMetric(
                  'الديون المضافة',
                  '${formatter.format(debits)} $symbol',
                  AppIcons.debt,
                  AppColors.debtRed,
                ),
                _analyticsMetric(
                  'المبالغ المحصلة',
                  '${formatter.format(credits)} $symbol',
                  AppIcons.payment,
                  AppColors.paymentGreen,
                ),
                _analyticsMetric(
                  'صافي حركة الفترة',
                  '${formatter.format(net)} $symbol',
                  Icons.account_balance_wallet_outlined,
                  net >= 0 ? AppColors.warning : AppColors.paymentGreen,
                ),
                _analyticsMetric(
                  'نسبة التحصيل',
                  '${formatter.format(collectionRate)}%',
                  Icons.percent_rounded,
                  AppColors.primary,
                ),
              ],
            ),
            const SizedBox(height: 14),
            _analyticsCard(
              title: 'حركة آخر 7 أيام',
              subtitle: 'الأحمر ديون، والأخضر تحصيلات - $currency',
              child: SizedBox(
                height: 150,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: daily.map((item) {
                    final debitHeight = maxDaily == 0
                        ? 2.0
                        : 105 * item.debits / maxDaily;
                    final creditHeight = maxDaily == 0
                        ? 2.0
                        : 105 * item.credits / maxDaily;
                    return Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Container(
                                  width: 9,
                                  height: debitHeight,
                                  decoration: BoxDecoration(
                                    color: AppColors.debtRed,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                const SizedBox(width: 3),
                                Container(
                                  width: 9,
                                  height: creditHeight,
                                  decoration: BoxDecoration(
                                    color: AppColors.paymentGreen,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            DateFormat('E', 'ar').format(item.day),
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 14),
            _analyticsCard(
              title: 'أعلى العملاء مديونية',
              subtitle: 'الرصيد الحالي مستقل عن نطاق الفترة',
              child: topDebtors.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Center(
                        child: Text('لا توجد أرصدة مدينة بهذه العملة'),
                      ),
                    )
                  : Column(
                      children: topDebtors.take(5).map((item) {
                        final maxDebt = topDebtors.first.value;
                        return InkWell(
                          onTap: () => Navigator.pushNamed(
                            context,
                            AppRoutes.customerLedger,
                            arguments: item.key,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        item.key.localDisplayName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${formatter.format(item.value)} $symbol',
                                      style: const TextStyle(
                                        color: AppColors.debtRed,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                LinearProgressIndicator(
                                  value: maxDebt == 0
                                      ? 0
                                      : item.value / maxDebt,
                                  minHeight: 5,
                                  color: AppColors.debtRed,
                                  backgroundColor: AppColors.debtRed.withValues(
                                    alpha: 0.08,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
            ),
            const SizedBox(height: 14),
            _analyticsCard(
              title: 'قراءة سريعة',
              subtitle: '${entries.length} عملية خلال النطاق المحدد',
              child: Text(
                entries.isEmpty
                    ? 'لا توجد عمليات بعملة $currency خلال هذه الفترة. غيّر الفترة أو العملة.'
                    : collectionRate >= 80
                    ? 'التحصيل مرتفع مقارنة بالديون الجديدة خلال الفترة. استمر بمتابعة الأرصدة القديمة.'
                    : collectionRate >= 40
                    ? 'التحصيل متوسط. راجع العملاء الأعلى مديونية وحدد مواعيد متابعة.'
                    : 'التحصيل منخفض مقابل الديون الجديدة. يُنصح بمتابعة الاستحقاقات والعملاء ذوي الأرصدة الأعلى.',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  height: 1.6,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _analyticsMetric(
    String label,
    String value,
    IconData icon,
    Color color,
  ) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(17),
      border: Border.all(color: AppColors.borderLight),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Icon(icon, color: color, size: 20),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w900,
            fontSize: 15,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
        ),
      ],
    ),
  );

  Widget _analyticsCard({
    required String title,
    required String subtitle,
    required Widget child,
  }) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(19),
      border: Border.all(color: AppColors.borderLight),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w900,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
        ),
        const SizedBox(height: 14),
        child,
      ],
    ),
  );

  Widget _buildProfileTab() => const SizedBox.shrink();
}

/// ورقة اختيار العميل التفاعلية عند تسجيل دين أو سداد
class _CustomerPickerSheet extends StatefulWidget {
  final List<BusinessCustomerModel> customers;
  final String actionTitle;
  final ValueChanged<BusinessCustomerModel> onSelected;

  const _CustomerPickerSheet({
    required this.customers,
    required this.actionTitle,
    required this.onSelected,
  });

  @override
  State<_CustomerPickerSheet> createState() => _CustomerPickerSheetState();
}

class _CustomerPickerSheetState extends State<_CustomerPickerSheet> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.customers.where((c) {
      final q = _filter.trim().toLowerCase();
      if (q.isEmpty) return true;
      return c.localDisplayName.toLowerCase().contains(q) ||
          (c.phone?.contains(q) ?? false);
    }).toList();

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // مقبض السحب
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.actionTitle,
                    style: AppTypography.titleMedium(
                      color: AppColors.textPrimary,
                    ).copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: TextField(
              onChanged: (val) => setState(() => _filter = val),
              decoration: InputDecoration(
                hintText: 'ابحث باسم العميل...',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                filled: true,
                fillColor: AppColors.backgroundLight,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 60),
              itemBuilder: (ctx, idx) {
                final customer = filtered[idx];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: AppColors.primaryContainer,
                    child: Text(
                      customer.localDisplayName.isNotEmpty
                          ? customer.localDisplayName[0]
                          : 'ع',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  title: Text(
                    customer.localDisplayName,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    customer.phone ?? 'بدون رقم',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted,
                    ),
                  ),
                  trailing: const Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 14,
                    color: AppColors.textMuted,
                  ),
                  onTap: () => widget.onSelected(customer),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
