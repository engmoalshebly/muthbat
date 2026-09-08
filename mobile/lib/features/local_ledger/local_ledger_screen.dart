import 'package:muthbat/shared/widgets/top_notice.dart';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../app/router/app_routes.dart';
import '../../core/config/supabase_config.dart';
import '../auth/presentation/controllers/auth_controller.dart';
import '../auth/presentation/validators/auth_validators.dart';
import 'local_ledger_store.dart';
import 'local_ledger_pdf.dart';
import 'local_analytics.dart';

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
          title: const Text('ابدأ دفتر البقالة'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 120,
                decoration: const InputDecoration(
                  labelText: 'اسم البقالة (اختياري)',
                  hintText: 'بقالتي',
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

  Future<void> entry({String? customerId}) async {
    final name = TextEditingController();
    final amount = TextEditingController();
    final description = TextEditingController();
    String type = 'debt';
    String? customer = customerId;
    final customers = doc!['customers'] as List;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('سجّل عملية'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: customer ?? '',
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'العميل'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('عميل جديد')),
                    ...customers.map(
                      (c) => DropdownMenuItem<String>(
                        value: c['id'],
                        child: Text(c['name']),
                      ),
                    ),
                  ],
                  onChanged: (v) => update(() => customer = v == '' ? null : v),
                ),
                if (customer == null)
                  TextField(
                    controller: name,
                    maxLength: 120,
                    decoration: const InputDecoration(labelText: 'اسم العميل'),
                  ),
                DropdownButtonFormField<String>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: 'نوع العملية'),
                  items: const [
                    DropdownMenuItem(value: 'debt', child: Text('دين — عليه')),
                    DropdownMenuItem(
                      value: 'payment',
                      child: Text('دفعة — سداد'),
                    ),
                    DropdownMenuItem(
                      value: 'discount',
                      child: Text('خصم من الدين'),
                    ),
                  ],
                  onChanged: (v) => update(() => type = v!),
                ),
                TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'المبلغ (${doc!['currency']})',
                  ),
                ),
                TextField(
                  controller: description,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: 'البيان (اختياري)',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('حفظ على الجهاز'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) {
      await run(() async {
        final id = await store.record(
          customerId: customer,
          customerName: name.text,
          type: type,
          amount: amount.text,
          description: description.text,
        );
        if (mounted) setState(() => selected = id);
      });
    }
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
    try {
      await client
          .rpc('local_notebook_import_version')
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      throw StateError(
        'خدمة نقل الدفتر لم تصبح متاحة بعد. تابع العمل محليًا واحتفظ بنسخة احتياطية.',
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
        result['business_id'] is! String) {
      throw StateError(
        'لم يكتمل التحقق من النقل. أعد المحاولة؛ النسخة المحلية محفوظة.',
      );
    }
    await store.completeTransfer(user.id, result['business_id']);
    if (mounted) {
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
      appBar: AppBar(
        title: Text(customer?['name'] ?? d?['name'] ?? 'مُثبَت'),
        leading: customer == null
            ? null
            : IconButton(
                onPressed: () => setState(() => selected = null),
                icon: const Icon(Icons.arrow_back),
              ),
        actions: [
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
                  await Navigator.pushNamed(context, AppRoutes.login);
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
                        const Icon(Icons.menu_book_rounded, size: 76),
                        const SizedBox(height: 24),
                        Text(
                          'دفتر بقالتك، جاهز من أول لحظة',
                          style: Theme.of(context).textTheme.headlineSmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'سجّل العملاء والديون والدفعات دون حساب ودون إنترنت.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: busy ? null : setup,
                          child: const Text('ابدأ دفتر البقالة'),
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
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          : Column(
              children: [
                if (busy) const LinearProgressIndicator(),
                MaterialBanner(
                  content: Text(
                    d['transfer_state'] == 'complete'
                        ? 'نُقل هذا الدفتر إلى الحساب. هذه نسخة محلية محفوظة للقراءة.'
                        : frozen
                        ? 'النقل قيد الاستكمال. أعد المحاولة بالحساب نفسه.'
                        : 'محفوظ على هذا الجهاز • الحساب اختياري',
                  ),
                  actions: [
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => run(
                              d['transfer_state'] == 'complete'
                                  ? () async {
                                      await Navigator.pushNamed(
                                        context,
                                        AppRoutes.login,
                                      );
                                    }
                                  : activateCloud,
                            ),
                      child: Text(
                        d['transfer_state'] == 'complete'
                            ? 'فتح الحساب'
                            : frozen
                            ? 'استكمال النقل'
                            : 'حفظ سحابي',
                      ),
                    ),
                  ],
                ),
                if (customer == null)
                  Flexible(
                    child: SingleChildScrollView(
                      child: LocalAnalytics(document: d),
                    ),
                  ),
                if (customer == null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      onChanged: (v) => setState(() => search = v),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'ابحث عن عميل',
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'الرصيد: ${LocalLedgerStore.money(LocalLedgerStore.balance(d, selected!))} ${d['currency']}',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: 'مشاركة كشف PDF',
                          onPressed: busy
                              ? null
                              : () => run(() async {
                                  await shareBytes(
                                    await localLedgerPdf(
                                      d,
                                      JsonMap.from(customer),
                                    ),
                                    'statement-${customer['id']}.pdf',
                                    'application/pdf',
                                  );
                                }),
                          icon: const Icon(Icons.picture_as_pdf),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: customer == null
                      ? customers.isEmpty
                            ? const Center(
                                child: Text(
                                  'ابدأ بإضافة أول عميل ودين من الزر أدناه.',
                                ),
                              )
                            : ListView(
                                children: customers
                                    .where(
                                      (c) => (c['name'] as String).contains(
                                        search,
                                      ),
                                    )
                                    .map<Widget>((c) {
                                      final balance = LocalLedgerStore.balance(
                                        d,
                                        c['id'],
                                      );
                                      return ListTile(
                                        leading: const CircleAvatar(
                                          child: Icon(Icons.person_outline),
                                        ),
                                        title: Text(c['name']),
                                        subtitle: Text(
                                          balance < 0
                                              ? 'له رصيد عند البقالة'
                                              : balance == 0
                                              ? 'الحساب مسدد'
                                              : 'عليه للبقالة',
                                        ),
                                        trailing: Text(
                                          '${LocalLedgerStore.money(balance.abs())} ${d['currency']}',
                                        ),
                                        onTap: () =>
                                            setState(() => selected = c['id']),
                                      );
                                    })
                                    .toList(),
                              )
                      : ListView(
                          children: entries
                              .where((e) => e['customer_id'] == selected)
                              .toList()
                              .reversed
                              .map<Widget>((e) {
                                final reversed = entries.any(
                                  (r) => r['reverses'] == e['id'],
                                );
                                return ListTile(
                                  title: Text(
                                    '${LocalLedgerStore.labels[e['type']]} • ${LocalLedgerStore.money(e['minor'])} ${d['currency']}',
                                  ),
                                  subtitle: Text(
                                    '${e['description']}\n${(e['occurred_at'] as String).substring(0, 10)}${reversed ? ' • عُكست' : ''}',
                                  ),
                                  isThreeLine: true,
                                  trailing:
                                      !frozen &&
                                          !reversed &&
                                          e['type'] != 'reversal'
                                      ? IconButton(
                                          tooltip: 'عكس العملية',
                                          onPressed: busy
                                              ? null
                                              : () => reverse(JsonMap.from(e)),
                                          icon: const Icon(Icons.undo),
                                        )
                                      : null,
                                );
                              })
                              .toList(),
                        ),
                ),
                const SizedBox(height: 80),
              ],
            ),
      floatingActionButton: d == null || frozen
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
      if (!otp && AuthValidators.passwordError(password.text) != null) {
        throw FormatException(AuthValidators.passwordError(password.text)!);
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
              : 'تعذر الاتصال؛ يمكنك الرجوع إلى دفتر البقالة.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        otp
            ? 'تأكيد الرقم'
            : signup
            ? 'احفظ دفتر بقالتك'
            : 'الدخول إلى حسابك',
      ),
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'بقالتك «${widget.businessName}» جاهزة. لا تحتاج إلى إدخال بياناتها من جديد.',
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
                helperText: '8 خانات على الأقل',
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
