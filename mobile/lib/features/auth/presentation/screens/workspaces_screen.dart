import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../local_ledger/local_ledger_store.dart';
import '../controllers/auth_controller.dart';
import '../workspace_navigation.dart';

class WorkspacesScreen extends ConsumerStatefulWidget {
  const WorkspacesScreen({super.key});
  @override
  ConsumerState<WorkspacesScreen> createState() => _WorkspacesScreenState();
}

class _WorkspacesScreenState extends ConsumerState<WorkspacesScreen> {
  List<JsonMap>? notebooks;
  bool busy = false;
  bool checkingMembership = false;
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _loadNotebooks();
    if (!mounted) return;
    await ref
        .read(authControllerProvider.notifier)
        .refreshLocalBusinessAccess();
  }

  Future<void> _loadNotebooks() async {
    try {
      final rows = await LocalLedgerStore.instance.notebooks();
      if (mounted) setState(() => notebooks = rows);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'تعذر قراءة دفاتر الجهاز. أعد المحاولة.');
      }
    }
  }

  Future<void> _refreshMembership() async {
    var auth = ref.read(authControllerProvider);
    if (!auth.hasLocalAccess) return;
    setState(() => checkingMembership = true);
    final message = await ref
        .read(authControllerProvider.notifier)
        .refreshCloudBusinessAccess();
    if (!mounted) return;
    setState(() {
      checkingMembership = false;
      if (message != null) error = message;
    });
  }

  Future<void> _open(String kind, {JsonMap? notebook}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final route = await prepareWorkspaceNavigation(
        auth: ref.read(authControllerProvider.notifier),
        kind: kind,
        notebook: notebook,
      );
      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(context, route, (_) => false);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is StateError
              ? e.message.toString()
              : 'تعذر فتح المساحة. أعد المحاولة.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _tile(
    String title,
    String subtitle,
    IconData icon,
    VoidCallback action,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(
      color: AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.borderLight),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(icon, color: AppColors.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_left_rounded),
        onTap: busy ? null : action,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(title: const Text('مساحاتي')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'اختر المساحة التي تريد فتحها',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text('تنقّل بين دفاترك وحسابك دون تسجيل خروج.'),
          if (busy || checkingMembership) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                error!,
                style: const TextStyle(color: AppColors.debtRed),
              ),
            ),
          const SizedBox(height: 24),
          const Text(
            'دفاتر هذا الجهاز',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (notebooks == null && error == null)
            const Center(child: CircularProgressIndicator()),
          for (final notebook in notebooks ?? <JsonMap>[])
            _tile(
              notebook['name'].toString(),
              notebook['transfer_state'] == 'complete'
                  ? 'نسخة منقولة • للقراءة'
                  : notebook['transfer_state'] == 'local'
                  ? 'دفتر محلي • يعمل دون إنترنت'
                  : 'نقل قيد الاستكمال • نسخة للقراءة',
              Icons.menu_book_outlined,
              () => _open('local', notebook: notebook),
            ),
          if (notebooks?.isEmpty == true)
            _tile(
              'دفتر حسابي',
              'ابدأ دفترًا على هذا الجهاز',
              Icons.add_rounded,
              () => _open('local'),
            ),
          const SizedBox(height: 20),
          const Text(
            'حسابي',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: checkingMembership ? null : _refreshMembership,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('تحديث الحسابات'),
            ),
          ),
          const SizedBox(height: 12),
          if (auth.hasLocalAccess) ...[
            _tile(
              'حساباتي كزبون',
              'حساباتي وطلباتي لدى التجار',
              Icons.person_outline_rounded,
              () => _open('customer'),
            ),
            _tile(
              auth.businessAccessChecked &&
                      auth.activeBusinessId != null &&
                      auth.businessRole != null
                  ? 'نشاطي التجاري'
                  : auth.requiresBusinessSetup
                  ? 'إعداد النشاط التجاري'
                  : 'الرجوع إلى حساب التاجر',
              auth.businessAccessChecked &&
                      auth.activeBusinessId != null &&
                      auth.businessRole != null
                  ? 'العملاء والعمليات والمزامنة'
                  : auth.requiresBusinessSetup
                  ? 'أكمل إنشاء متجرك على هذا الحساب'
                  : checkingMembership
                  ? 'جارٍ التحقق من عضويتك التجارية… اضغط لإعادة المحاولة'
                  : 'اضغط للتحقق من عضوية نشاطك التجاري وفتحه',
              Icons.storefront_outlined,
              () => _open('merchant'),
            ),
          ] else
            _tile(
              'تسجيل الدخول',
              'افتح حسابك مع الاحتفاظ بدفاتر الجهاز',
              Icons.login_rounded,
              () => Navigator.pushNamed(context, AppRoutes.login),
            ),
        ],
      ),
    );
  }
}
