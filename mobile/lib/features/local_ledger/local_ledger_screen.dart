import '../../app/theme/app_typography.dart';
import 'local_pdf_preview.dart';
import '../../shared/widgets/brand_logo.dart';
import '../../core/security/cloud_session.dart';
import 'package:muthbat/shared/widgets/top_notice.dart';
import 'dart:convert';
import 'dart:io';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../app/router/app_routes.dart';
import '../../app/theme/app_colors.dart';
import '../../core/config/supabase_config.dart';
import '../../core/database/db_encryption.dart';
import '../../core/database/app_database.dart';
import '../auth/presentation/controllers/auth_controller.dart';
import '../auth/presentation/validators/auth_validators.dart';
import 'local_ledger_store.dart';
import '../auth/presentation/workspace_preference.dart';
import '../auth/presentation/widgets/workspace_switcher.dart';
import 'local_transfer_backup.dart';
import 'local_palette.dart';
import '../../app/theme/app_icons.dart';
import 'local_ledger_pdf.dart';
import 'local_analytics.dart';
import 'local_directory.dart';
import 'local_entry_screen.dart';
import 'local_customer_screen.dart';

/// The local route does not instantiate AuthController or wait for the network.
class LocalLedgerScreen extends StatefulWidget {
  const LocalLedgerScreen({super.key, this.store});
  final LocalLedgerStore? store;
  @override
  State<LocalLedgerScreen> createState() => _LocalLedgerScreenState();
}

class _LocalLedgerScreenState extends State<LocalLedgerScreen> {
  ButtonStyle get _headerActionStyle => IconButton.styleFrom(
    foregroundColor: AppColors.primary,
    backgroundColor: AppColors.primaryContainer,
    disabledBackgroundColor: AppColors.surfaceContainerSoft,
    disabledForegroundColor: AppColors.textMuted,
    minimumSize: const Size(38, 38),
    maximumSize: const Size(38, 38),
    padding: const EdgeInsets.all(9),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
  );
  LocalLedgerStore get store => widget.store ?? LocalLedgerStore.instance;
  JsonMap? doc;
  String? error;
  bool loading = true;
  bool busy = false;
  String search = '';
  String? selected;
  int tab = 0;

  Widget _quickAction(
    IconData icon,
    String label,
    VoidCallback? onTap, {
    Color tint = AppColors.primary,
  }) => Material(
    color: AppColors.surfaceLight,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: AppColors.borderLight),
    ),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: onTap == null
                    ? AppColors.surfaceContainerSoft
                    : tint.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                icon,
                size: 20,
                color: onTap == null ? AppColors.textMuted : tint,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> openAccount() async {
    if (!SupabaseConfig.cloudReady) {
      throw StateError('الحساب غير متاح في هذه النسخة. دفتر جهازك محفوظ.');
    }
    final container = ProviderScope.containerOf(context, listen: false);
    await container.read(authControllerProvider.notifier).ready;
    if (!mounted) return;
    final account = container.read(authControllerProvider);
    final transferred =
        doc?['transfer_state'] == 'complete' &&
        doc?['owner_id'] == account.userId;
    if (transferred) {
      final businessId = doc?['server_business_id'] as String?;
      if (businessId == null) {
        throw StateError('معرّف النشاط المنقول غير موجود.');
      }
      if (account.activeBusinessId != businessId ||
          !account.businessAccessChecked) {
        await container
            .read(authControllerProvider.notifier)
            .activateImportedBusiness(businessId);
        if (!mounted) return;
      }
    }
    final route = !account.hasLocalAccess
        ? AppRoutes.login
        : transferred
        ? AppRoutes.merchantHome
        : account.userType == 'customer'
        ? AppRoutes.customerHome
        : account.requiresBusinessSetup
        ? AppRoutes.businessSetup
        : AppRoutes.merchantHome;
    if (route == AppRoutes.customerHome || route == AppRoutes.merchantHome) {
      await WorkspacePreference.save(
        account.userId,
        route == AppRoutes.customerHome ? 'customer' : 'merchant',
      );
      if (!mounted) return;
    }
    await Navigator.pushNamed(context, route);
    await reload();
  }

  Future<void> backup() async {
    final password = await _promptBackupPassword();
    if (password == null) return; // dialog dismissed/cancelled
    await shareBytes(
      utf8.encode(
        await store.backup(password: password.isEmpty ? null : password),
      ),
      'muthbat-backup-${DateTime.now().millisecondsSinceEpoch}.json',
      'application/json',
    );
  }

  Future<void> saveLocalBackup() async {
    final password = await _promptBackupPassword();
    if (password == null || !mounted) return;
    final contents = await store.backup(
      password: password.isEmpty ? null : password,
    );
    final path = await FileSaver.instance.saveAs(
      name: 'muthbat-backup-${DateTime.now().millisecondsSinceEpoch}',
      bytes: Uint8List.fromList(utf8.encode(contents)),
      fileExtension: 'json',
      mimeType: MimeType.custom,
      customMimeType: 'application/json',
    );
    if (!mounted || path == null || path.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(
          Icons.check_circle_rounded,
          color: AppColors.success,
          size: 36,
        ),
        title: const Text('تم حفظ النسخة بنجاح', textAlign: TextAlign.center),
        content: const Text(
          'يمكنك الوصول إلى نسختك الاحتياطية من تطبيق الملفات واستعادتها عند الحاجة.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, height: 1.6),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('حسنًا'),
          ),
        ],
      ),
    );
  }

  Future<void> openSettings() async {
    bool working = false;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (settingsContext) => StatefulBuilder(
          builder: (settingsContext, update) {
            Future<void> action(Future<void> Function() task) async {
              if (working) return;
              update(() => working = true);
              try {
                await run(task);
              } finally {
                if (settingsContext.mounted) update(() => working = false);
              }
            }

            Widget option(
              IconData icon,
              String title,
              String subtitle,
              Future<void> Function()? task,
            ) => Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 7),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(13),
                side: const BorderSide(color: AppColors.borderLight),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 3,
                ),
                leading: Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: AppColors.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: AppColors.primary, size: 19),
                ),
                title: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: AppColors.textPrimary,
                  ),
                ),
                subtitle: Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    height: 1.5,
                  ),
                ),
                trailing: const Icon(
                  AppIcons.chevronEnd,
                  size: 16,
                  color: AppColors.textMuted,
                ),
                onTap: working || task == null ? null : () => action(task),
              ),
            );
            return Scaffold(
              backgroundColor: AppColors.backgroundLight,
              appBar: AppBar(
                backgroundColor: AppColors.backgroundLight,
                foregroundColor: AppColors.textPrimary,
                toolbarHeight: 56,
                titleSpacing: 4,
                title: const Text(
                  'الإعدادات',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                actions: const [
                  Padding(
                    padding: EdgeInsetsDirectional.only(end: 16),
                    child: BrandLogo.icon(width: 35, height: 35),
                  ),
                ],
              ),
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (working) const LinearProgressIndicator(),
                  Container(
                    margin: const EdgeInsets.only(bottom: 20),
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      gradient: AppColors.cardGradient,
                      borderRadius: BorderRadius.circular(17),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.white.withValues(alpha: .14),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.tune_rounded,
                            size: 24,
                            color: AppColors.white,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                doc?['name']?.toString() ?? 'مُثبَت',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 21,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.white,
                                ),
                              ),
                              const SizedBox(height: 3),
                              const Text(
                                'دفاترك، نسخك الاحتياطية وحماية حسابك',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textWhiteSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Text(
                    'دفاتر الحساب',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryDark,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'اختر الدفتر الذي تريد العمل عليه.',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  option(
                    Icons.library_books_outlined,
                    'التبديل بين الدفاتر',
                    'فتح الدفتر الأصلي أو أي نسخة مستعادة',
                    () async {
                      final notebooks = await store.notebooks();
                      if (!settingsContext.mounted) return;
                      final id = await showModalBottomSheet<String>(
                        context: settingsContext,
                        isScrollControlled: true,
                        builder: (sheetContext) => SafeArea(
                          child: SizedBox(
                            height: MediaQuery.sizeOf(sheetContext).height * .6,
                            child: Column(
                              children: [
                                const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Text(
                                    'دفاتر الحساب',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: ListView.builder(
                                    itemCount: notebooks.length,
                                    itemBuilder: (_, i) {
                                      final notebook = notebooks[i];
                                      final active =
                                          notebook['id'] == doc?['id'];
                                      return ListTile(
                                        leading: Icon(
                                          active
                                              ? Icons.check_circle_rounded
                                              : Icons.book_outlined,
                                          color: AppColors.primary,
                                        ),
                                        title: Text(
                                          notebook['name'].toString(),
                                        ),
                                        subtitle: Text(
                                          '${(notebook['customers'] as List).length} عميل • ${(notebook['entries'] as List).length} حركة • ${notebook['currency']}',
                                        ),
                                        trailing: active
                                            ? const Text('الحالي')
                                            : null,
                                        onTap: () => Navigator.pop(
                                          sheetContext,
                                          notebook['id'].toString(),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                      if (id == null || !mounted) return;
                      await store.selectNotebook(id);
                      setState(() {
                        selected = null;
                        tab = 0;
                      });
                      await reload();
                    },
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'النسخ الاحتياطي والاستعادة',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryDark,
                    ),
                  ),
                  const SizedBox(height: 10),
                  option(
                    Icons.save_alt_rounded,
                    'حفظ نسخة على الجهاز',
                    'اختر مجلدًا على الجهاز لحفظ ملف النسخة',
                    doc == null ? null : saveLocalBackup,
                  ),
                  option(
                    AppIcons.share,
                    'مشاركة نسخة احتياطية',
                    'إنشاء ملف ومشاركته مع اختيار حماية بكلمة مرور',
                    doc == null ? null : backup,
                  ),
                  const SizedBox(height: 12),
                  option(
                    Icons.restore_rounded,
                    'استعادة من ملف',
                    'اختيار نسخة احتياطية بصيغة JSON',
                    restore,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    doc != null
                        ? 'تُفتح النسخة المستعادة كدفتر منفصل، مع الاحتفاظ بدفترك الحالي.'
                        : 'أنشئ دفترًا أو استعد نسخة لتفعيل خيارات الحفظ.',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'الأمان',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryDark,
                    ),
                  ),
                  const SizedBox(height: 12),
                  option(
                    AppIcons.lock,
                    'قفل التطبيق والبصمة',
                    'إدارة حماية الدخول على هذا الجهاز',
                    () async {
                      await Navigator.pushNamed(
                        settingsContext,
                        AppRoutes.appLockSettings,
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'المساعدة',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryDark,
                    ),
                  ),
                  const SizedBox(height: 12),
                  option(
                    AppIcons.whatsapp,
                    'دردشة الدعم',
                    'التواصل مع فريق الدعم',
                    () async {
                      await Navigator.pushNamed(
                        settingsContext,
                        AppRoutes.daraiChat,
                      );
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Returns the chosen password, `''` when the user opted out of
  /// protection, or `null` when the dialog was cancelled/dismissed.
  Future<String?> _promptBackupPassword() async {
    final controller = TextEditingController();
    final confirmController = TextEditingController();
    var protect = true;
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('نسخة احتياطية'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'يمكنك حماية النسخة بكلمة مرور حتى لا يقرأها أحد إن وصلت إلى شخص آخر.',
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: protect,
                    onChanged: (v) => setDialogState(() => protect = v ?? true),
                    title: const Text('حماية النسخة بكلمة مرور'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  if (protect) ...[
                    TextField(
                      controller: controller,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'كلمة المرور',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: confirmController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'تأكيد كلمة المرور',
                      ),
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(error!, style: const TextStyle(color: AppColors.red)),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () {
                  if (!protect) {
                    Navigator.pop(context, '');
                    return;
                  }
                  if (controller.text.length < 6) {
                    setDialogState(
                      () => error = 'كلمة المرور 6 أحرف على الأقل',
                    );
                    return;
                  }
                  if (controller.text != confirmController.text) {
                    setDialogState(() => error = 'كلمتا المرور غير متطابقتين');
                    return;
                  }
                  Navigator.pop(context, controller.text);
                },
                child: const Text('إنشاء النسخة'),
              ),
            ],
          );
        },
      ),
    );
    return result;
  }

  Widget accountPanel(JsonMap d) {
    final complete = d['transfer_state'] == 'complete';
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LocalPalette.hero,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.menu_book_rounded,
                color: LocalPalette.gold,
                size: 32,
              ),
              const SizedBox(height: 12),
              Text(
                d['name'].toString(),
                style: const TextStyle(
                  color: AppColors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                complete
                    ? 'نسخة محلية محفوظة بعد النقل'
                    : 'دفتر حساب محلي • يعمل دون إنترنت',
                style: const TextStyle(color: AppColors.white),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.payments_outlined),
                title: const Text('العملة الأساسية'),
                subtitle: Text(d['currency'].toString()),
              ),
              ListTile(
                leading: const Icon(Icons.people_outline),
                title: const Text('العملاء'),
                subtitle: Text('${(d['customers'] as List).length} عميل'),
              ),
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: const Text('الحركات المسجلة'),
                subtitle: Text('${(d['entries'] as List).length} حركة'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: busy ? null : openSettings,
          icon: const Icon(Icons.settings_outlined, size: 19),
          label: const Text('الإعدادات'),
        ),
        const SizedBox(height: 12),
        const Text(
          'تُحفظ بيانات هذا الدفتر على جهازك. احفظ نسخة احتياطية من الإعدادات لاستعادتها عند الحاجة.',
        ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final value = await store.current();
      if (mounted) {
        setState(() {
          doc = value;
          loading = false;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          error = 'تعذر فتح الدفتر. لم تُحذف أي بيانات.';
          loading = false;
        });
      }
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
      await reload();
    } catch (e) {
      if (mounted) {
        String? serviceMessage;
        if (e is FunctionException && e.details is Map) {
          final problem = (e.details as Map)['error'];
          if (problem is Map && problem['message'] is String) {
            serviceMessage = problem['message'] as String;
          }
        }
        TopNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is FormatException
                  ? e.message
                  : e is StateError
                  ? e.message.toString()
                  : serviceMessage ??
                        'تعذر إكمال العملية. بياناتك محفوظة؛ حاول مجددًا.',
            ),
          ),
        );
      }
    } finally {
      await reload();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> setup() async {
    final name = TextEditingController();
    String currency = 'YER';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('ابدأ دفتر حساب'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 120,
                decoration: const InputDecoration(
                  labelText: 'اسم الدفتر (اختياري)',
                  hintText: 'حساباتي',
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: currency,
                decoration: const InputDecoration(labelText: 'العملة الأساسية'),
                items: const [
                  DropdownMenuItem(value: 'YER', child: Text('ريال يمني')),
                  DropdownMenuItem(value: 'SAR', child: Text('ريال سعودي')),
                  DropdownMenuItem(value: 'USD', child: Text('دولار أمريكي')),
                ],
                onChanged: (v) => update(() => currency = v!),
              ),
              const SizedBox(height: 12),
              const Text(
                'يمكنك تعديل التفاصيل لاحقًا. عملة القيود ثابتة منذ أول عملية.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('رجوع'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('ابدأ'),
            ),
          ],
        ),
      ),
    );
    final value = name.text;
    // Dialog route animations may still reference its controllers.
    if (accepted == true) await run(() => store.create(value, currency));
  }

  Future<void> addCustomer() async {
    if (busy || doc == null || doc!['transfer_state'] != 'local') return;
    final id = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => LocalCustomerScreen(store: store)),
    );
    if (!mounted) return;
    await reload();
    if (!mounted || id == null) return;
    setState(() {
      tab = 1;
      selected = id;
    });
  }

  Future<void> entry({String? customerId, String initialType = 'debt'}) async {
    if (busy || doc == null) return;
    final id = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => LocalEntryScreen(
          store: store,
          document: doc!,
          customerId: customerId,
          initialType: initialType,
        ),
      ),
    );
    if (!mounted) return;
    if (id != null) setState(() => selected = id);
    await reload();
  }

  Future<void> reverse(JsonMap e) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('عكس العملية'),
        content: TextField(
          controller: reason,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: 'سبب العكس',
            helperText: 'يبقى الأصل محفوظًا ويضاف قيد معاكس.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('عكس'),
          ),
        ],
      ),
    );
    if (ok == true) await run(() => store.reverse(e['id'], reason.text));
  }

  Future<void> shareBytes(List<int> bytes, String filename, String mime) async {
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mime)],
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  Future<void> restore() async {
    final result = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null) return;
    if (await result.length() > 20 * 1024 * 1024) {
      throw const FormatException('الملف أكبر من الحجم المدعوم');
    }
    final text = utf8.decode(await result.readAsBytes());
    String? password;
    if (LocalLedgerStore.looksLikeEncryptedBackup(text)) {
      password = await _promptRestorePassword();
      if (password == null) return; // cancelled
    }
    await store.restore(text, password: password);
    if (!mounted) return;
    setState(() {
      selected = null;
      tab = 0;
    });
    await reload();
    if (mounted) {
      TopNotice.of(context).showSnackBar(
        const SnackBar(content: Text('تم استعادة النسخة وفتحها كدفتر منفصل.')),
      );
    }
  }

  Future<String?> _promptRestorePassword() async {
    final controller = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('نسخة محمية بكلمة مرور'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'كلمة المرور'),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: const TextStyle(color: AppColors.red)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                if (controller.text.isEmpty) {
                  setDialogState(() => error = 'أدخل كلمة المرور');
                  return;
                }
                Navigator.pop(context, controller.text);
              },
              child: const Text('استعادة'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> activateCloud() async {
    final reviewed = jsonDecode(jsonEncode(doc!)) as JsonMap;
    final summary = LocalLedgerStore.transferSummary(reviewed);
    final categoryCount = summary['category_count'] as int;
    if (!SupabaseConfig.cloudReady) {
      throw StateError(
        'الاتصال بالحساب غير متاح في هذه النسخة. يمكنك مواصلة العمل محليًا.',
      );
    }
    if (!canUseCloudSession(
      Supabase.instance.client.auth.currentSession,
      AppDatabase.instance.accountId,
    )) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => LocalAccountScreen(businessName: doc!['name']),
        ),
      );
      if (!mounted || Supabase.instance.client.auth.currentUser == null) return;
    }
    final client = Supabase.instance.client;
    requireCloudSession(client, AppDatabase.instance.accountId);
    final user = client.auth.currentUser!;
    if (reviewed['owner_id'] != null && reviewed['owner_id'] != user.id) {
      throw StateError(
        'سجّل الدخول بالحساب المرتبط بهذا الدفتر لاستكمال النقل.',
      );
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تفعيل الحفظ السحابي'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'سيُنشأ متجر مستقل باسم «${doc!['name']}» في حساب ${user.phone ?? ''}. لن يُدمج مع أي متجر موجود.',
              ),
              const SizedBox(height: 16),
              Text('العملاء: ${summary['customer_count']}'),
              Text('القيود: ${summary['entry_count']}'),
              Text('التصنيفات: ${summary['category_count']}'),
              Text('العملة: ${summary['currency']}'),
              Text(
                'صافي الأرصدة: ${LocalLedgerStore.money(summary['balance_minor'] as int)} ${summary['currency']}',
              ),
              Text(
                'عملاء عليهم رصيد: ${summary['positive_balance_count']} • أرصدة مقدمة: ${summary['advance_balance_count']}',
              ),
              const SizedBox(height: 16),
              const Text(
                'ستُنشأ نسخة احتياطية مشفرة تلقائيًا قبل الرفع. بعد الحجز لا يمكن نقل الدفتر إلى حساب آخر، وإذا انقطع الاتصال يمكنك الاستئناف بالحساب نفسه.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء النقل'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('إنشاء متجر مستقل ونقل الدفتر'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // Check deployment BEFORE freezing the local notebook.
    dynamic importVersion;
    try {
      importVersion = await client
          .rpc('local_notebook_import_version')
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      throw StateError(
        'خدمة نقل الدفتر لم تصبح متاحة بعد. تابع العمل محليًا واحتفظ بنسخة احتياطية.',
      );
    }
    if (importVersion is! int || importVersion < 6) {
      throw StateError(
        'يلزم تحديث خدمة النقل لحفظ بيانات العملاء وتواريخ الحركات. دفتر الحساب ما زال متاحًا محليًا.',
      );
    }
    final capabilities = await client.functions
        .invoke(
          'local-notebook-import',
          body: {
            'action': 'capabilities',
            'notebook': {...reviewed, 'owner_id': user.id},
          },
        )
        .timeout(const Duration(seconds: 15));
    if (capabilities.data is! Map ||
        capabilities.data['version'] is! int ||
        capabilities.data['version'] < 6) {
      throw StateError(
        'خدمة نقل بيانات العملاء غير جاهزة. يمكنك متابعة العمل محليًا.',
      );
    }
    final backupDirectory = await getApplicationSupportDirectory();
    final transferBackupDirectory = Directory(
      '${backupDirectory.path}/transfer-backups',
    );
    final backupPassword = await DbEncryptionKeyStore().passphraseFor(
      'local_transfer_backup_${reviewed['id']}',
    );
    final backupFile = await ensureLocalTransferBackup(
      snapshot: reviewed,
      directory: transferBackupDirectory,
      password: backupPassword,
    );
    requireCloudSession(client, user.id);
    if (AppDatabase.instance.accountId != user.id) {
      throw StateError('تغيّر الحساب قبل النقل.');
    }
    final snapshot = await store.reserveTransfer(
      user.id,
      expectedSnapshot: reviewed,
    );
    await store.markTransferCheckpoint(
      user.id,
      'backup_created',
      backupPath: backupFile.path,
      notebookId: snapshot['id'] as String,
    );
    final response = await client.functions
        .invoke('local-notebook-import', body: {'notebook': snapshot})
        .timeout(const Duration(seconds: 60));
    final result = response.data;
    if (client.auth.currentUser?.id != user.id) {
      throw StateError(
        'تغيّر الحساب. أعد تسجيل الدخول بالحساب المرتبط لاستكمال النقل.',
      );
    }
    await store.markTransferCheckpoint(
      user.id,
      'uploaded',
      notebookId: snapshot['id'] as String,
    );
    if (result is! Map ||
        result['entry_count'] != (snapshot['entries'] as List).length ||
        result['customer_count'] != (snapshot['customers'] as List).length ||
        result['phone_count'] !=
            (snapshot['customers'] as List)
                .where((c) => (c['phone'] as String? ?? '').trim().isNotEmpty)
                .length ||
        result['business_id'] is! String ||
        (categoryCount > 0 && result['category_count'] != categoryCount)) {
      throw StateError(
        'لم يكتمل التحقق من النقل. أعد المحاولة؛ النسخة المحلية محفوظة.',
      );
    }
    final verification = await client
        .rpc(
          'verify_local_notebook_import',
          params: {'p_notebook_id': snapshot['id']},
        )
        .timeout(const Duration(seconds: 30));
    if (verification is! Map ||
        verification['verified'] != true ||
        verification['business_id'] != result['business_id'] ||
        verification['customer_count'] != summary['customer_count'] ||
        verification['entry_count'] != summary['entry_count'] ||
        verification['category_count'] != summary['category_count'] ||
        verification['currency'] != summary['currency'] ||
        verification['balance_minor'] != summary['balance_minor']) {
      throw StateError(
        'بيانات الخادم لا تطابق الدفتر المحلي. لم يُعلن نجاح النقل ويمكن استئنافه بأمان.',
      );
    }
    requireCloudSession(client, user.id);
    if (AppDatabase.instance.accountId != user.id) {
      throw StateError('تغيّر الحساب أثناء التحقق.');
    }
    await store.markTransferCheckpoint(
      user.id,
      'verified',
      notebookId: snapshot['id'] as String,
    );
    await store.completeTransfer(
      user.id,
      result['business_id'],
      notebookId: snapshot['id'] as String,
    );
    await reload();
    if (!mounted) return;
    final container = ProviderScope.containerOf(context, listen: false);
    await container
        .read(authControllerProvider.notifier)
        .activateImportedBusiness(result['business_id'] as String);
    if (mounted) {
      setState(() => tab = 3);
      TopNotice.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'تم نقل الدفتر وبيانات العملاء. حسابك جاهز لمواصلة العمل.',
          ),
        ),
      );
      await Navigator.pushNamed(context, AppRoutes.merchantHome);
      if (mounted) await reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = doc;
    final customers = d == null ? <dynamic>[] : d['customers'] as List;
    final entries = d == null ? <dynamic>[] : d['entries'] as List;
    final homeEntries = LocalLedgerStore.chronological(
      entries,
    ).reversed.toList();
    final frozen = d != null && d['transfer_state'] != 'local';
    final customer = selected == null
        ? null
        : customers.where((c) => c['id'] == selected).firstOrNull;
    return Scaffold(
      backgroundColor: LocalPalette.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundLight,
        foregroundColor: AppColors.textPrimary,
        toolbarHeight: 56,
        shape: const Border(bottom: BorderSide(color: AppColors.borderLight)),
        centerTitle: false,
        titleSpacing: 12,
        automaticallyImplyLeading: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.dark.copyWith(
          statusBarColor: AppColors.transparent,
        ),
        titleTextStyle: const TextStyle(
          fontFamily: AppTypography.fontFamily,
          fontSize: 19,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
        title: Row(
          children: [
            if (customer == null) ...[
              WorkspaceSwitcherButton(
                currentKind: 'local',
                name: d?['name'] as String?,
                notebookId: d?['id'] as String?,
                store: store,
                enabled: !busy,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    customer?['name'] ?? d?['name'] ?? 'مُثبَت | دفتر حساب',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (customer == null && d != null && tab == 0)
                    Tooltip(
                      message: frozen
                          ? 'نسخة محلية • راجع حالة النقل في الحساب'
                          : 'محفوظ على جهازك • يعمل دون إنترنت',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            frozen
                                ? AppIcons.pendingUpload
                                : AppIcons.shieldCheck,
                            size: 12,
                            color: AppColors.primary,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              frozen ? 'نسخة محلية' : 'دفتر محلي • دون إنترنت',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (customer == null && (d == null || tab != 0))
                    Text(
                      d == null
                          ? 'حساباتك ببساطة'
                          : [
                              'دفتر حساب شخصي',
                              'العملاء',
                              'التقارير',
                              'إدارة الحساب',
                            ][tab],
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  if (customer != null && customer['phone'] != null)
                    Text(
                      customer['phone'].toString(),
                      textDirection: TextDirection.ltr,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        leading: customer == null && tab == 0
            ? null
            : IconButton(
                iconSize: 20,
                onPressed: () => setState(() {
                  if (selected != null) {
                    selected = null;
                  } else {
                    tab = 0;
                  }
                }),
                tooltip: 'رجوع',
                icon: const Icon(AppIcons.chevronStart),
              ),
        actions: [
          IconButton(
            tooltip: 'الإعدادات',
            iconSize: 19,
            onPressed: busy ? null : openSettings,
            icon: const Icon(AppIcons.settings),
            style: _headerActionStyle,
          ),
          if (d != null)
            IconButton(
              iconSize: 19,
              tooltip: 'الحساب',
              style: _headerActionStyle,
              onPressed: busy
                  ? null
                  : () => setState(() {
                      selected = null;
                      tab = 3;
                    }),
              icon: const Icon(AppIcons.profile),
            ),
          if (d != null)
            IconButton(
              tooltip: 'التقارير',
              icon: const Icon(AppIcons.reports),
              iconSize: 19,
              style: _headerActionStyle,
              onPressed: busy
                  ? null
                  : () => setState(() {
                      selected = null;
                      tab = 2;
                    }),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(error!),
                  TextButton(
                    onPressed: reload,
                    child: const Text('إعادة المحاولة'),
                  ),
                ],
              ),
            )
          : d == null
          ? Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            gradient: LocalPalette.hero,
                            borderRadius: BorderRadius.circular(32),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.primary.withValues(alpha: .16),
                                blurRadius: 30,
                                offset: const Offset(0, 12),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.menu_book_rounded,
                            size: 44,
                            color: LocalPalette.gold,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'دفتر حسابك، جاهز من أول لحظة',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: AppColors.primary,
                                fontWeight: FontWeight.w800,
                              ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'سجّل العملاء والديون والدفعات دون حساب ودون إنترنت.',
                          style: TextStyle(
                            color: LocalPalette.secondaryText,
                            fontSize: 15,
                            height: 1.6,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: LocalPalette.teal,
                            minimumSize: const Size(double.infinity, 54),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: busy ? null : setup,
                          child: const Text('ابدأ دفتر حساب'),
                        ),
                        TextButton(
                          onPressed: busy || !SupabaseConfig.cloudReady
                              ? null
                              : () => Navigator.pushNamed(
                                  context,
                                  AppRoutes.login,
                                ),
                          child: const Text('لدي حساب'),
                        ),
                        OutlinedButton.icon(
                          onPressed: busy ? null : openSettings,
                          icon: const Icon(Icons.settings_outlined, size: 18),
                          label: const Text('الإعدادات'),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'عند حذف التطبيق، اختر «الاحتفاظ ببيانات التطبيق» إذا ظهر الخيار. الاحتفاظ يعتمد على نظام الهاتف، وإعادة التثبيت تحتاج نسخة بالتوقيع نفسه. صدّر نسخة احتياطية خارج التطبيق لضمان إمكانية استعادة دفترك إذا حُذفت البيانات أو مفاتيح التشفير.',
                          style: TextStyle(
                            color: LocalPalette.secondaryText,
                            fontSize: 13,
                            height: 1.6,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          : customer == null && tab == 3
          ? accountPanel(d)
          : customer == null && (tab == 0 || tab == 2)
          ? ListView.builder(
              padding: const EdgeInsets.only(bottom: 100),
              itemCount: 1 + (tab == 0 ? homeEntries.length : 0),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (busy) const LinearProgressIndicator(),
                      LocalAnalytics(document: d, summaryOnly: tab == 0),
                      if (tab == 0) ...[
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Expanded(
                                child: _quickAction(
                                  AppIcons.customers,
                                  'العملاء',
                                  () => setState(() => tab = 1),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _quickAction(
                                  AppIcons.receipt,
                                  'تسجيل دين',
                                  frozen || busy ? null : () => entry(),
                                  tint: AppColors.debt,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _quickAction(
                                  AppIcons.cash,
                                  'تسجيل دفعة',
                                  frozen || busy
                                      ? null
                                      : () => entry(initialType: 'payment'),
                                  tint: AppColors.payment,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Card(
                            child: ListTile(
                              leading: const Icon(
                                AppIcons.pendingUpload,
                                color: LocalPalette.teal,
                              ),
                              title: Text(
                                frozen
                                    ? 'متابعة حالة نقل الدفتر'
                                    : 'دفترك جاهز لحساب التاجر',
                              ),
                              subtitle: const Text(
                                'نفس العملاء والعمليات، دون البدء من جديد',
                              ),
                              trailing: const Icon(AppIcons.chevronEnd),
                              onTap: () => setState(() => tab = 3),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                          child: Text(
                            'جميع العمليات (${homeEntries.length})',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (entries.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              'سجّل أول دين أو دفعة من الاختصارات أعلاه.',
                            ),
                          ),
                      ],
                    ],
                  );
                }
                final e = homeEntries[index - 1];
                final owner = customers
                    .where((c) => c['id'] == e['customer_id'])
                    .firstOrNull;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Material(
                    color: AppColors.white,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => setState(() => selected = e['customer_id']),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppColors.transactionColor(
                                  e['type'].toString(),
                                ).withValues(alpha: .10),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(
                                e['type'] == 'discount'
                                    ? AppIcons.discount
                                    : e['direction'] == 'debit'
                                    ? AppIcons.debt
                                    : AppIcons.receivePayment,
                                color: AppColors.transactionColor(
                                  e['type'].toString(),
                                ),
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${LocalLedgerStore.labels[e['type']]} · ${owner?['name'] ?? 'عميل'}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    '${LocalLedgerStore.labels[e['type']]} ? ${LocalLedgerStore.localDate(e['occurred_at'])}',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: LocalPalette.secondaryText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                '${LocalLedgerStore.money(e['minor'])} ${d['currency']}',
                                textAlign: TextAlign.end,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.transactionColor(
                                    e['type'].toString(),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            )
          : LocalDirectory(
              key: ValueKey(selected ?? 'directory'),
              document: d,
              customerId: selected,
              busy: busy,
              onOpen: (id) => setState(() => selected = id),
              onReverse: reverse,
              onPdf: () async {
                if (busy) return;
                setState(() => busy = true);
                try {
                  final bytes = await localLedgerPdf(
                    d,
                    JsonMap.from(customer!),
                  );
                  if (!context.mounted) return;
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LocalPdfPreview(
                        bytes: bytes,
                        filename: 'statement-${customer['id']}',
                      ),
                    ),
                  );
                } catch (error, stack) {
                  debugPrint('PDF generation failed: $error\n$stack');
                  if (context.mounted) {
                    TopNotice.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('تعذر إنشاء تقرير PDF. حاول مجددًا.'),
                      ),
                    );
                  }
                } finally {
                  if (mounted) setState(() => busy = false);
                }
              },
            ),
      floatingActionButton: d == null || frozen || (customer == null && tab > 1)
          ? null
          : FloatingActionButton.extended(
              onPressed: busy
                  ? null
                  : customer == null && tab == 1
                  ? addCustomer
                  : () => entry(customerId: selected),
              icon: const Icon(Icons.add),
              label: Text(
                customer == null && tab == 1 ? 'إضافة عميل' : 'دين / دفعة',
              ),
            ),
    );
  }
}

class LocalAccountScreen extends ConsumerStatefulWidget {
  const LocalAccountScreen({super.key, required this.businessName});
  final String businessName;
  @override
  ConsumerState<LocalAccountScreen> createState() => _LocalAccountScreenState();
}

class _LocalAccountScreenState extends ConsumerState<LocalAccountScreen> {
  final phone = TextEditingController();
  final password = TextEditingController();
  final code = TextEditingController();
  bool signup = true;
  bool busy = false;
  bool otp = false;
  bool obscure = true;
  String? error;
  @override
  void dispose() {
    phone.dispose();
    password.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final controller = ref.read(authControllerProvider.notifier);
      final raw = LocalLedgerStore.normalizeDigits(phone.text.trim());
      final normalized = raw.startsWith('+')
          ? raw
          : raw.startsWith('967')
          ? '+$raw'
          : '+967$raw';
      if (!otp && !RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(normalized)) {
        throw const FormatException('أدخل رقم الهاتف مع مفتاح الدولة');
      }
      if (!otp &&
          signup &&
          AuthValidators.passwordError(password.text) != null) {
        throw FormatException(AuthValidators.passwordError(password.text)!);
      }
      if (!otp && !signup && password.text.isEmpty) {
        throw const FormatException('أدخل كلمة المرور');
      }
      final ok = otp
          ? await controller.verifySignupOtp(code.text)
          : signup
          ? await controller.registerStart(
              name: widget.businessName,
              phone: normalized,
              password: password.text,
              userType: 'merchant',
            )
          : await controller.loginWithPassword(
              phone: normalized,
              password: password.text,
            );
      if (!mounted) return;
      final state = ref.read(authControllerProvider);
      if (ok && state.status == AuthStatus.authenticated) {
        Navigator.pop(context);
        return;
      }
      if (ok && state.status == AuthStatus.otpSent) {
        setState(() => otp = true);
      } else {
        setState(
          () => error = state.errorMessage ?? 'تعذر إكمال الطلب؛ حاول مجددًا.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException
              ? e.message
              : 'تعذر الاتصال؛ يمكنك الرجوع إلى دفتر حساب.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: LocalPalette.canvas,
    appBar: AppBar(
      backgroundColor: AppColors.primary,
      foregroundColor: AppColors.white,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      titleTextStyle: Theme.of(context).textTheme.titleLarge?.copyWith(
        color: AppColors.white,
        fontWeight: FontWeight.w700,
      ),
      title: Text(
        otp
            ? 'تأكيد الرقم'
            : signup
            ? 'احفظ دفتر حسابك'
            : 'الدخول إلى حسابك',
      ),
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LocalPalette.hero,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.cloud_done_outlined,
                  color: LocalPalette.gold,
                  size: 40,
                ),
                const SizedBox(height: 16),
                Text(
                  otp
                      ? 'خطوة واحدة لتأكيد هويتك'
                      : 'دفترك معك في الخطوة التالية',
                  style: const TextStyle(
                    color: AppColors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'دفترك «${widget.businessName}» جاهزة. لا تحتاج إلى إدخال بياناتها من جديد.',
                  style: const TextStyle(color: AppColors.white),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'تأكيد الحساب ← مراجعة البيانات ← نقل الدفتر',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          if (otp)
            TextField(
              controller: code,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'رمز التحقق'),
            )
          else ...[
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                labelText: 'رقم الهاتف',
                hintText: '+967…',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: password,
              obscureText: obscure,
              decoration: InputDecoration(
                labelText: 'كلمة المرور',
                helperText: signup ? '8 خانات على الأقل' : null,
                suffixIcon: IconButton(
                  onPressed: () => setState(() => obscure = !obscure),
                  icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                ),
              ),
            ),
          ],
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 24),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(54),
              backgroundColor: LocalPalette.teal,
            ),
            onPressed: busy ? null : submit,
            child: Text(
              busy
                  ? 'جارٍ الإكمال…'
                  : otp
                  ? 'تأكيد'
                  : signup
                  ? 'إنشاء الحساب'
                  : 'دخول',
            ),
          ),
          if (!otp)
            TextButton(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      signup = !signup;
                      error = null;
                    }),
              child: Text(signup ? 'لدي حساب بالفعل' : 'إنشاء حساب جديد'),
            ),
          const Text('يمكنك الرجوع في أي وقت. يظل الدفتر محفوظًا على جهازك.'),
        ],
      ),
    ),
  );
}
