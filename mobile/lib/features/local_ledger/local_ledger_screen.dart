import 'package:muthbat/shared/widgets/top_notice.dart';
import 'dart:convert';
import 'dart:io';
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
import '../auth/presentation/controllers/auth_controller.dart';
import '../auth/presentation/validators/auth_validators.dart';
import 'local_ledger_store.dart';
import 'local_palette.dart';
import 'local_ledger_pdf.dart';
import 'local_analytics.dart';
import 'local_directory.dart';
import 'local_entry_screen.dart';

/// The local route does not instantiate AuthController or wait for the network.
class LocalLedgerScreen extends StatefulWidget {
  const LocalLedgerScreen({super.key, this.store});
  final LocalLedgerStore? store;
  @override
  State<LocalLedgerScreen> createState() => _LocalLedgerScreenState();
}

class _LocalLedgerScreenState extends State<LocalLedgerScreen> {
  LocalLedgerStore get store => widget.store ?? LocalLedgerStore.instance;
  JsonMap? doc;
  String? error;
  bool loading = true;
  bool busy = false;
  String search = '';
  String? selected;
  int tab = 0;

  Widget _quickAction(IconData icon, String label, VoidCallback? onTap) =>
      Material(
        color: onTap == null ? Colors.white : LocalPalette.mint,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: onTap == null ? Colors.white : LocalPalette.teal,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    size: 24,
                    color: onTap == null ? AppColors.textMuted : Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: LocalPalette.ink,
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
    final route = account.status != AuthStatus.authenticated
        ? AppRoutes.login
        : transferred
        ? AppRoutes.merchantHome
        : account.userType == 'customer'
        ? AppRoutes.customerHome
        : account.requiresBusinessSetup
        ? AppRoutes.businessSetup
        : AppRoutes.merchantHome;
    await Navigator.pushNamed(context, route);
    await reload();
  }

  Future<void> backup() async => shareBytes(
    utf8.encode(await store.backup()),
    'muthbat-backup-${DateTime.now().millisecondsSinceEpoch}.json',
    'application/json',
  );

  Widget accountPanel(JsonMap d) {
    final complete = d['transfer_state'] == 'complete';
    final pending = d['transfer_state'] != 'local' && !complete;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LocalPalette.hero,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.storefront_rounded,
                color: LocalPalette.gold,
                size: 28,
              ),
              const SizedBox(height: 8),
              Text(
                d['name'],
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                complete
                    ? 'نسخة محلية محفوظة بعد النقل'
                    : 'دفترك يعمل دون إنترنت ودون اشتراك',
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          complete ? 'تم نقل دفتر حسابك' : 'انتقل إلى حساب تاجر، بنفس بياناتك',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        const Text(
          'الحساب اختياري. تسجيل الدخول وحده لا ينقل الدفتر؛ ستراجع البيانات وتؤكد الربط أولًا.',
        ),
        const SizedBox(height: 16),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text(
            'كيف أنقل دفتري؟',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          leading: const Icon(
            Icons.cloud_upload_outlined,
            color: LocalPalette.teal,
          ),
          children: [
            const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Text('1')),
              title: Text('إنشاء حساب أو تسجيل الدخول'),
              subtitle: Text('برقمك، دون إعادة إدخال تفاصيل الدفتر'),
            ),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(child: Text('2')),
              title: const Text('مراجعة الدفتر وتأكيد نقله'),
              subtitle: Text(
                '${(d['customers'] as List).length} عميل • ${(d['entries'] as List).length} عملية • ${d['currency']}',
              ),
            ),
            const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Text('3')),
              title: Text('متابعة العمل من حساب التاجر'),
              subtitle: Text(
                'تبقى نسخة الدفتر على هذا الجهاز للقراءة بعد نجاح النقل',
              ),
            ),
          ],
        ),
        if (pending)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'النقل لم يكتمل. استكمله بالحساب نفسه؛ لا تنشئ دفترًا بديلًا.',
            ),
          ),
        FilledButton.icon(
          onPressed: busy
              ? null
              : () => run(complete ? openAccount : activateCloud),
          icon: Icon(complete ? Icons.storefront : Icons.cloud_upload_outlined),
          label: Text(
            complete
                ? 'متابعة إلى الحساب'
                : pending
                ? 'استكمال نقل الدفتر'
                : 'تفعيل حساب التاجر',
          ),
        ),
        const SizedBox(height: 24),
        Card(
          child: ListTile(
            leading: const Icon(Icons.save_alt),
            title: const Text('حفظ نسخة احتياطية'),
            subtitle: const Text('لحماية الدفتر عند فقد الهاتف أو حذف التطبيق'),
            trailing: const Icon(Icons.chevron_left),
            onTap: busy ? null : () => run(backup),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'الحفظ المحلي ليس نسخة سحابية. تفعيل الحساب ونقل البيانات يحتاجان اتصالًا بالإنترنت.',
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
        TopNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is FormatException
                  ? e.message
                  : e is StateError
                  ? e.message.toString()
                  : 'تعذر إكمال العملية. بياناتك محفوظة؛ حاول مجددًا.',
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
    final bytes = await result.readAsBytes();
    await store.restore(utf8.decode(bytes));
  }

  Future<void> activateCloud() async {
    final categoryCount = (doc?['entries'] as List? ?? [])
        .where((e) => e['category'] != null)
        .length;
    if (!SupabaseConfig.cloudReady) {
      throw StateError(
        'الاتصال بالحساب غير متاح في هذه النسخة. يمكنك مواصلة العمل محليًا.',
      );
    }
    if (Supabase.instance.client.auth.currentUser == null) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => LocalAccountScreen(businessName: doc!['name']),
        ),
      );
      if (!mounted || Supabase.instance.client.auth.currentUser == null) return;
    }
    final client = Supabase.instance.client;
    final user = client.auth.currentUser!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تفعيل الحفظ السحابي'),
        content: Text(
          'سيُضاف دفتر «${doc!['name']}» كبقالة مستقلة إلى حساب ${user.phone ?? ''}. لن تُدمج بقالة أخرى معه. يتوقف تعديل الدفتر أثناء النقل؛ إذا انقطع الاتصال أعد المحاولة بالحساب نفسه.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('لاحقًا'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('ربط الدفتر'),
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
    if (importVersion is! int || importVersion < (categoryCount > 0 ? 2 : 1)) {
      throw StateError(
        'يلزم تحديث خدمة النقل لحفظ التصنيفات. دفتر الحساب ما زال متاحًا محليًا.',
      );
    }
    final snapshot = await store.reserveTransfer(user.id);
    final result = await client
        .rpc('import_local_notebook', params: {'p_notebook': snapshot})
        .timeout(const Duration(seconds: 60));
    if (client.auth.currentUser?.id != user.id) {
      throw StateError(
        'تغيّر الحساب. أعد تسجيل الدخول بالحساب المرتبط لاستكمال النقل.',
      );
    }
    if (result is! Map ||
        result['entry_count'] != (snapshot['entries'] as List).length ||
        result['customer_count'] != (snapshot['customers'] as List).length ||
        result['business_id'] is! String ||
        (categoryCount > 0 && result['category_count'] != categoryCount)) {
      throw StateError(
        'لم يكتمل التحقق من النقل. أعد المحاولة؛ النسخة المحلية محفوظة.',
      );
    }
    await store.completeTransfer(user.id, result['business_id']);
    await reload();
    if (mounted) {
      setState(() => tab = 3);
      TopNotice.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم نقل الدفتر. افتح الحساب لمواصلة العمل والمزامنة.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = doc;
    final customers = d == null ? <dynamic>[] : d['customers'] as List;
    final entries = d == null ? <dynamic>[] : d['entries'] as List;
    final frozen = d != null && d['transfer_state'] != 'local';
    final customer = selected == null
        ? null
        : customers.where((c) => c['id'] == selected).firstOrNull;
    return Scaffold(
      backgroundColor: LocalPalette.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        toolbarHeight: 64,
        centerTitle: false,
        titleSpacing: 16,
        automaticallyImplyLeading: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
        ),
        titleTextStyle: const TextStyle(
          fontFamily: 'Tajawal',
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              customer?['name'] ?? d?['name'] ?? 'مُثبَت | دفتر حساب',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (customer == null)
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
                  fontSize: 12,
                  color: AppColors.textWhiteSecondary,
                ),
              ),
          ],
        ),
        leading: customer == null && tab == 0
            ? null
            : IconButton(
                onPressed: () => setState(() {
                  if (selected != null) {
                    selected = null;
                  } else {
                    tab = 0;
                  }
                }),
                icon: const Icon(Icons.arrow_back),
              ),
        actions: [
          if (d != null) ...[
            IconButton(
              tooltip: 'التقارير',
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: .10),
              ),
              onPressed: () => setState(() {
                selected = null;
                tab = 2;
              }),
              icon: const Icon(Icons.bar_chart),
            ),
            IconButton(
              tooltip: 'الحساب',
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: .10),
              ),
              onPressed: () => setState(() {
                selected = null;
                tab = 3;
              }),
              icon: const Icon(Icons.person_outline),
            ),
          ],
          if (d != null)
            PopupMenuButton<String>(
              enabled: !busy,
              onSelected: (v) => run(() async {
                if (v == 'backup') {
                  await shareBytes(
                    utf8.encode(await store.backup()),
                    'muthbat-backup-${DateTime.now().millisecondsSinceEpoch}.json',
                    'application/json',
                  );
                } else if (v == 'cloud') {
                  await activateCloud();
                } else if (v == 'account') {
                  await openAccount();
                }
              }),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'backup',
                  child: Text('نسخة احتياطية قابلة للاستعادة'),
                ),
                PopupMenuItem(
                  value: 'cloud',
                  child: Text('تفعيل الحساب ونقل الدفتر'),
                ),
                PopupMenuItem(
                  value: 'account',
                  child: Text('فتح حسابي السحابي'),
                ),
              ],
            ),
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
                            fontSize: 14,
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
                        TextButton(
                          onPressed: busy ? null : () => run(restore),
                          child: const Text('استعادة نسخة احتياطية'),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'بياناتك محفوظة على هذا الجهاز. صدّر نسخة احتياطية لحمايتها عند فقد الهاتف أو حذف التطبيق.',
                          style: TextStyle(
                            color: LocalPalette.secondaryText,
                            fontSize: 12,
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
          ? ListView(
              padding: const EdgeInsets.only(bottom: 100),
              children: [
                if (busy) const LinearProgressIndicator(),
                if (tab == 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.offline_pin_outlined,
                          color: LocalPalette.teal,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            frozen
                                ? 'نسخة محلية • راجع حالة النقل في الحساب'
                                : 'محفوظ على جهازك • يعمل دون إنترنت',
                          ),
                        ),
                      ],
                    ),
                  ),
                LocalAnalytics(document: d, summaryOnly: tab == 0),
                if (tab == 0) ...[
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: _quickAction(
                            Icons.people_outline,
                            'العملاء',
                            () => setState(() => tab = 1),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _quickAction(
                            Icons.receipt_long_outlined,
                            'تسجيل دين',
                            frozen || busy ? null : () => entry(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _quickAction(
                            Icons.payments_outlined,
                            'تسجيل دفعة',
                            frozen || busy
                                ? null
                                : () => entry(initialType: 'payment'),
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
                          Icons.cloud_upload_outlined,
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
                        trailing: const Icon(Icons.chevron_left),
                        onTap: () => setState(() => tab = 3),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: Text(
                      'آخر العمليات',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (entries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('سجّل أول دين أو دفعة من الاختصارات أعلاه.'),
                    ),
                  ...LocalLedgerStore.chronological(
                    entries,
                  ).reversed.take(5).map((e) {
                    final owner = customers
                        .where((c) => c['id'] == e['customer_id'])
                        .firstOrNull;
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () =>
                              setState(() => selected = e['customer_id']),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Icon(
                                  e['direction'] == 'debit'
                                      ? Icons.receipt_long_outlined
                                      : Icons.payments_outlined,
                                  color: LocalPalette.teal,
                                  size: 22,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${LocalLedgerStore.labels[e['type']]} · ${owner?['name'] ?? 'عميل'}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Text(
                                        LocalLedgerStore.localDate(
                                          e['occurred_at'],
                                        ),
                                        style: const TextStyle(
                                          fontSize: 12,
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
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: e['direction'] == 'debit'
                                          ? LocalPalette.debt
                                          : LocalPalette.payment,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ],
            )
          : LocalDirectory(
              key: ValueKey(selected ?? 'directory'),
              document: d,
              customerId: selected,
              busy: busy,
              onOpen: (id) => setState(() => selected = id),
              onReverse: reverse,
              onPdf: () => run(() async {
                await shareBytes(
                  await localLedgerPdf(d, JsonMap.from(customer!)),
                  'statement-${customer['id']}.pdf',
                  'application/pdf',
                );
              }),
            ),
      floatingActionButton: d == null || frozen || (customer == null && tab > 1)
          ? null
          : FloatingActionButton.extended(
              onPressed: busy ? null : () => entry(customerId: selected),
              icon: const Icon(Icons.add),
              label: const Text('دين / دفعة'),
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
      foregroundColor: Colors.white,
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
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'دفترك «${widget.businessName}» جاهزة. لا تحتاج إلى إدخال بياناتها من جديد.',
                  style: const TextStyle(color: Colors.white),
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
