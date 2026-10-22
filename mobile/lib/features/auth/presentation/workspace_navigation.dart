import '../../../app/router/app_routes.dart';
import '../../local_ledger/local_ledger_store.dart';
import 'controllers/auth_controller.dart';
import 'customer_entry_mode.dart';
import 'workspace_preference.dart';

/// Local navigation only: this never refreshes cloud membership or signs out.
Future<String> prepareWorkspaceNavigation({
  AuthController? auth,
  required String kind,
  JsonMap? notebook,
  LocalLedgerStore? store,
}) async {
  final owner = auth?.currentState.userId;
  void ensureCurrent() {
    if (auth != null && (!auth.mounted || auth.currentState.userId != owner)) {
      throw StateError('تغير الحساب. افتح قائمة الحسابات مجددًا.');
    }
  }

  String route;
  String? notebookId;
  if (kind == 'local') {
    final ledger = store ?? LocalLedgerStore.instance;
    notebookId = notebook?['id'] as String?;
    if (notebookId != null) await ledger.selectNotebook(notebookId);
    notebookId ??= (await ledger.current())?['id'] as String?;
    route = AppRoutes.localLedger;
  } else {
    if (auth == null || !auth.currentState.hasLocalAccess || owner == null) {
      throw StateError('سجّل الدخول لفتح الحساب.');
    }
    if (kind == 'merchant') {
      await auth.refreshLocalBusinessAccess();
      ensureCurrent();
      final state = auth.currentState;
      if (state.requiresBusinessSetup) {
        route = AppRoutes.businessSetup;
      } else if (state.businessAccessChecked &&
          state.activeBusinessId != null &&
          state.businessRole != null) {
        route = AppRoutes.merchantHome;
      } else {
        throw StateError(
          'لا توجد بيانات متجر متاحة على هذا الجهاز. افتح مساحاتي لتحديث الحسابات.',
        );
      }
    } else if (kind == 'customer') {
      await auth.prepareCustomerWorkspace();
      route = AppRoutes.customerHome;
    } else {
      throw ArgumentError.value(kind, 'kind');
    }
    ensureCurrent();
    if (!auth.currentState.hasLocalAccess) throw StateError('تغيرت جلسة الحساب.');
    await CustomerEntryMode.remember(owner, kind == 'customer');
  }
  ensureCurrent();
  await WorkspacePreference.save(owner, kind, notebookId: notebookId);
  ensureCurrent();
  return route;
}
