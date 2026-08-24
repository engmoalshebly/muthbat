import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/config/supabase_config.dart';
import '../../../../shared/widgets/brand_logo.dart';
import '../../../../shared/widgets/muthbat_bottom_nav.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import '../controllers/merchant_controller.dart';

/// واجهة بروفايل التاجر الاحترافية
class MerchantProfileScreen extends ConsumerWidget {
  const MerchantProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);
    final merchantState = ref.watch(merchantControllerProvider);
    final currencyFormatter = NumberFormat('#,##0', 'ar');

    final userName = authState.displayName ?? 'التاجر';
    final phone = authState.phoneNumber ?? '+967 7XX XXX XXX';
    final userType = authState.userType == 'merchant'
        ? 'حساب تاجر'
        : 'حساب عميل';

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: SingleChildScrollView(
        child: Column(
          children: [
            // === ترويسة أفقية مدمجة ===
            Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                gradient: AppColors.brandGradient,
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(24),
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 18, 18),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(
                              AppIcons.chevronStart,
                              color: Colors.white,
                              size: 20,
                            ),
                            onPressed: () => Navigator.pop(context),
                          ),
                          const SizedBox(width: 4),
                          const Text(
                            'الإعدادات',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: 'تعديل ملف المنشأة',
                            onPressed: () => Navigator.pushNamed(
                              context,
                              AppRoutes.businessProfileEdit,
                            ),
                            icon: const Icon(
                              Icons.edit_outlined,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            width: 68,
                            height: 68,
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              border: Border.all(
                                color: AppColors.accentGold,
                                width: 2,
                              ),
                            ),
                            child: ClipOval(
                              child: merchantState.businessLogoPath.isNotEmpty
                                  ? Image.network(
                                      '${SupabaseConfig.effectiveUrl}/storage/v1/object/public/business-assets/${merchantState.businessLogoPath}',
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => _logoFallback(
                                        merchantState.businessName,
                                      ),
                                    )
                                  : _logoFallback(merchantState.businessName),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  merchantState.businessName.isNotEmpty
                                      ? merchantState.businessName
                                      : userName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '$userName • $userType',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  phone,
                                  textDirection: ui.TextDirection.ltr,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
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
            ).animate().fadeIn(duration: 400.ms),

            const SizedBox(height: 20),

            // === بطاقة إحصائيات سريعة ===
            Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.06),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        _buildStatItem(
                          icon: AppIcons.customers,
                          value: '${merchantState.customers.length}',
                          label: 'العملاء',
                          color: AppColors.secondary,
                        ),
                        _buildStatDivider(),
                        _buildStatItem(
                          icon: AppIcons.debt,
                          value: currencyFormatter.format(
                            merchantState.totalReceivables,
                          ),
                          label: 'إجمالي الذمم',
                          color: AppColors.debtRed,
                        ),
                        _buildStatDivider(),
                        _buildStatItem(
                          icon: AppIcons.dispute,
                          value: '${merchantState.openDisputesCount}',
                          label: 'النزاعات',
                          color: AppColors.warning,
                        ),
                      ],
                    ),
                  ),
                )
                .animate()
                .fadeIn(delay: 100.ms, duration: 400.ms)
                .slideY(begin: 0.1, end: 0),

            const SizedBox(height: 20),

            // === معلومات المنشأة ===
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.primaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            AppIcons.store,
                            color: AppColors.primary,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'معلومات المنشأة',
                          style: AppTypography.titleSmall(
                            color: AppColors.textPrimary,
                          ).copyWith(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _buildInfoRow(
                      AppIcons.store,
                      'اسم المنشأة',
                      merchantState.businessName,
                    ),
                    _buildInfoRow(
                      AppIcons.balance,
                      'العملة',
                      merchantState.currency,
                    ),
                    _buildInfoRow(
                      AppIcons.store,
                      'المدينة',
                      merchantState.businessCity.isNotEmpty
                          ? merchantState.businessCity
                          : 'غير محدد',
                    ),
                    _buildInfoRow(
                      Icons.location_on_outlined,
                      'العنوان',
                      merchantState.businessAddress.isNotEmpty
                          ? merchantState.businessAddress
                          : 'غير محدد',
                    ),
                    _buildInfoRow(
                      Icons.phone_outlined,
                      'التواصل',
                      merchantState.businessContactPhone.isNotEmpty
                          ? merchantState.businessContactPhone
                          : 'غير محدد',
                    ),
                    _buildInfoRow(
                      AppIcons.reports,
                      'النوع',
                      merchantState.businessType.isNotEmpty
                          ? merchantState.businessType
                          : 'غير محدد',
                    ),
                  ],
                ),
              ),
            ).animate().fadeIn(delay: 150.ms, duration: 400.ms),

            const SizedBox(height: 20),

            // === قائمة الإعدادات ===
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    _buildSettingsItem(
                      icon: AppIcons.store,
                      label: 'بيانات وملف المنشأة',
                      color: AppColors.primary,
                      trailing: const Text(
                        'تعديل',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                      onTap: () async {
                        await Navigator.pushNamed(
                          context,
                          AppRoutes.businessProfileEdit,
                        );
                        ref
                            .read(merchantControllerProvider.notifier)
                            .loadDashboard();
                      },
                    ),
                    _buildSettingsDivider(),
                    _buildSettingsItem(
                      icon: Icons.notifications_active_outlined,
                      label: 'الإشعارات والتنبيهات',
                      color: AppColors.warning,
                      trailing: const Text(
                        'إدارة',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                      onTap: () => _showNotificationSettings(context),
                    ),
                    _buildSettingsDivider(),
                    _buildSettingsItem(
                      icon: Icons.image_outlined,
                      label: 'شعار المنشأة',
                      color: AppColors.primary,
                      trailing: const Text(
                        'تغيير',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                      onTap: () async {
                        final image = await ImagePicker().pickImage(
                          source: ImageSource.gallery,
                          imageQuality: 90,
                          maxWidth: 1200,
                          maxHeight: 1200,
                        );
                        if (image == null) return;
                        final ok = await ref
                            .read(merchantControllerProvider.notifier)
                            .updateBusinessLogo(
                              bytes: await image.readAsBytes(),
                              extension: image.name.split('.').last,
                            );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              ok
                                  ? 'تم تحديث شعار المنشأة وسيظهر في ملفات PDF.'
                                  : ref
                                            .read(merchantControllerProvider)
                                            .lastError ??
                                        'تعذر تحديث الشعار.',
                            ),
                            backgroundColor: ok
                                ? AppColors.success
                                : AppColors.error,
                          ),
                        );
                      },
                    ),
                    _buildSettingsDivider(),
                    _buildSettingsItem(
                      icon: Icons.sync_rounded,
                      label: 'مزامنة البيانات الآن',
                      color: AppColors.success,
                      trailing: const Text(
                        'محلي وسحابي',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                      onTap: () async {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('جاري مزامنة البيانات...'),
                          ),
                        );
                        await ref
                            .read(merchantControllerProvider.notifier)
                            .syncNow();
                        if (!context.mounted) return;
                        final error = ref
                            .read(merchantControllerProvider)
                            .lastError;
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(
                            SnackBar(
                              content: Text(error ?? 'اكتملت المزامنة بنجاح.'),
                              backgroundColor: error == null
                                  ? AppColors.success
                                  : AppColors.error,
                            ),
                          );
                      },
                    ),
                    _buildSettingsDivider(),
                    _buildSettingsItem(
                      icon: AppIcons.balance,
                      label: 'إدارة العملات',
                      color: AppColors.secondary,
                      trailing: Text(
                        '${merchantState.supportedCurrencies.length} مفعلة',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                      onTap: () => Navigator.pushNamed(
                        context,
                        AppRoutes.currencySettings,
                      ),
                    ),
                    _buildSettingsDivider(),
                    _buildSettingsItem(
                      icon: AppIcons.lock,
                      label: 'تغيير كلمة السر',
                      color: AppColors.accentGoldDark,
                      onTap: () =>
                          Navigator.pushNamed(context, AppRoutes.resetPassword),
                    ),
                    _buildSettingsDivider(),
                    _buildSettingsItem(
                      icon: AppIcons.profile,
                      label: 'اللغة',
                      color: AppColors.primaryLight,
                      trailing: const Text(
                        'العربية',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                      onTap: () => _showLanguageSettings(context),
                    ),
                    _buildSettingsDivider(),
                    _buildSettingsItem(
                      icon: AppIcons.statement,
                      label: 'الشروط والأحكام',
                      color: AppColors.textSecondary,
                      onTap: () => _showTerms(context),
                    ),
                    _buildSettingsDivider(),
                    _buildSettingsItem(
                      icon: AppIcons.help,
                      label: 'الدعم الفني والمساعدة',
                      color: AppColors.secondary,
                      onTap: () => _showSupport(context, ref),
                    ),
                  ],
                ),
              ),
            ).animate().fadeIn(delay: 200.ms, duration: 400.ms),

            const SizedBox(height: 20),

            // === زر تسجيل الخروج ===
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.error.withValues(alpha: 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(22),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          title: const Text('تسجيل الخروج'),
                          content: const Text(
                            'هل أنت متأكد من رغبتك في تسجيل الخروج؟ سيتم حفظ بياناتك محلياً.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('إلغاء'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text(
                                'خروج',
                                style: TextStyle(
                                  color: AppColors.debtRed,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );

                      if (confirm == true && context.mounted) {
                        await ref
                            .read(authControllerProvider.notifier)
                            .signOut();
                        if (context.mounted) {
                          Navigator.pushNamedAndRemoveUntil(
                            context,
                            AppRoutes.login,
                            (r) => false,
                          );
                        }
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: AppColors.error.withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              AppIcons.close,
                              color: AppColors.debtRed,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Text(
                            'تسجيل الخروج',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppColors.debtRed,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ).animate().fadeIn(delay: 250.ms, duration: 400.ms),

            const SizedBox(height: 20),

            // === الشعار والإصدار ===
            const BrandLogo.icon(width: 28, height: 28),
            const SizedBox(height: 4),
            // Synced with pubspec.yaml version field
            const Text(
              'مُثبَت | MUTHBAT v1.0.0',
              style: TextStyle(fontSize: 10, color: AppColors.textMuted),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
      bottomNavigationBar: MuthbatBottomNav(
        currentIndex: 3,
        items: const [
          MuthbatNavItem(icon: AppIcons.home, label: 'الرئيسية'),
          MuthbatNavItem(icon: AppIcons.customers, label: 'العملاء'),
          MuthbatNavItem(icon: AppIcons.reports, label: 'التقارير'),
          MuthbatNavItem(icon: AppIcons.profile, label: 'الملف'),
        ],
        onTap: (index) {
          if (index == 3) return;
          Navigator.pushNamedAndRemoveUntil(
            context,
            AppRoutes.merchantHome,
            (route) => false,
            arguments: index,
          );
        },
      ),
    );
  }

  Future<void> _showLanguageSettings(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'لغة التطبيق',
              style: AppTypography.titleMedium(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'العربية هي اللغة المعتمدة حالياً لضمان اتجاه RTL الصحيح في الحسابات والتقارير.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 14),
            ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              tileColor: AppColors.primaryContainer,
              leading: const Icon(Icons.language, color: AppColors.primary),
              title: const Text('العربية'),
              subtitle: const Text('من اليمين إلى اليسار'),
              trailing: const Icon(
                Icons.check_circle,
                color: AppColors.success,
              ),
              onTap: () async {
                await prefs.setString('app_language', 'ar');
                if (sheetContext.mounted) Navigator.pop(sheetContext);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showNotificationSettings(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    var syncAlerts = prefs.getBool('notify_sync') ?? true;
    var paymentAlerts = prefs.getBool('notify_payments') ?? true;
    var disputeAlerts = prefs.getBool('notify_disputes') ?? true;
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'الإشعارات والتنبيهات',
                  style: AppTypography.titleMedium(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              SwitchListTile(
                title: const Text('حالة المزامنة'),
                subtitle: const Text('تنبيه عند اكتمال المزامنة أو تعذرها'),
                value: syncAlerts,
                onChanged: (value) async {
                  await prefs.setBool('notify_sync', value);
                  setSheetState(() => syncAlerts = value);
                },
              ),
              SwitchListTile(
                title: const Text('الدفعات والقيود'),
                subtitle: const Text('تنبيهات العمليات المالية الجديدة'),
                value: paymentAlerts,
                onChanged: (value) async {
                  await prefs.setBool('notify_payments', value);
                  setSheetState(() => paymentAlerts = value);
                },
              ),
              SwitchListTile(
                title: const Text('النزاعات والاعتراضات'),
                subtitle: const Text('تنبيه عند وصول اعتراض أو تحديثه'),
                value: disputeAlerts,
                onChanged: (value) async {
                  await prefs.setBool('notify_disputes', value);
                  setSheetState(() => disputeAlerts = value);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showTerms(BuildContext context) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('الشروط والأحكام'),
      content: const SingleChildScrollView(
        child: Text(
          'باستخدام تطبيق مُثبَت، يقر المستخدم بأن القيود المالية المدخلة مسؤوليته، وأن عليه مراجعة المبالغ والعملات وأسماء العملاء قبل التوثيق أو المشاركة.\n\n'
          'تُحفظ البيانات محلياً على الجهاز وتُزامن مع الخادم عند توفر الاتصال. يجب المحافظة على بيانات الدخول وعدم مشاركة رموز التحقق.\n\n'
          'ملفات PDF وكشوف الحساب أدوات توثيق ومراجعة، ولا تستبدل المتطلبات القانونية أو الضريبية الرسمية المطبقة في بلد المنشأة.',
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('فهمت'),
        ),
      ],
    ),
  );

  Future<void> _showSupport(BuildContext context, WidgetRef ref) {
    final state = ref.read(merchantControllerProvider);
    final diagnostics =
        'MUTHBAT v1.0.0\nBusiness: ${state.businessId}\nCurrencies: ${state.supportedCurrencies.join(', ')}\nLast error: ${state.lastError ?? 'none'}';
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'الدعم والمساعدة',
              style: AppTypography.titleMedium(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'إذا واجهت مشكلة، نفّذ المزامنة أولاً ثم انسخ معلومات التشخيص وأرسلها لمسؤول النظام.',
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: diagnostics));
                if (!sheetContext.mounted) return;
                ScaffoldMessenger.of(sheetContext).showSnackBar(
                  const SnackBar(content: Text('تم نسخ معلومات التشخيص.')),
                );
              },
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('نسخ معلومات التشخيص'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String value,
    required String label,
    required Color color,
  }) {
    return Expanded(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          Text(
            label,
            style: AppTypography.bodySmall(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _logoFallback(String businessName) {
    final letter = businessName.trim().isNotEmpty
        ? businessName.trim().characters.first
        : 'م';
    return Container(
      color: AppColors.primaryContainer,
      alignment: Alignment.center,
      child: Text(
        letter,
        style: const TextStyle(
          color: AppColors.primary,
          fontSize: 25,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _buildStatDivider() {
    return Container(width: 1, height: 45, color: AppColors.borderSubtle);
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Text(
            '$label:',
            style: AppTypography.bodySmall(
              color: AppColors.textSecondary,
            ).copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              style: AppTypography.bodyMedium(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.left,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsItem({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: AppTypography.titleSmall(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
              if (trailing != null) ...[trailing, const SizedBox(width: 6)],
              const Icon(
                AppIcons.chevronEnd,
                size: 18,
                color: AppColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Divider(height: 1, color: AppColors.borderSubtle),
    );
  }
}
