import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../core/config/supabase_config.dart';
import '../../../local_ledger/local_ledger_store.dart';
import '../controllers/auth_controller.dart';
import '../workspace_navigation.dart';

class WorkspaceChoice {
  final String kind, title, subtitle;
  final JsonMap? notebook;
  const WorkspaceChoice(this.kind, this.title, this.subtitle, {this.notebook});
  IconData get icon => switch (kind) {
    'merchant' => Icons.storefront_outlined,
    'customer' => Icons.person_outline_rounded,
    _ => Icons.menu_book_outlined,
  };
  bool matches(String current, String? notebookId) =>
      kind == current && (kind != 'local' || notebook?['id'] == notebookId);
}

List<WorkspaceChoice> availableWorkspaces(
  AuthState auth,
  List<JsonMap> notebooks,
) => [
  if (auth.hasLocalAccess) ...[
    const WorkspaceChoice('customer', 'حسابي كزبون', 'حساباتي لدى التجار'),
    if (auth.businessAccessChecked &&
        auth.activeBusinessId != null &&
        auth.businessRole != null)
      const WorkspaceChoice('merchant', 'حسابي كتاجر', 'متجري وعملائي'),
  ],
  for (final notebook in notebooks)
    WorkspaceChoice(
      'local',
      notebook['name']?.toString() ?? 'دفتر حسابي',
      notebook['transfer_state'] == 'local'
          ? 'دفتر محلي'
          : 'نسخة محلية • للقراءة',
      notebook: notebook,
    ),
  if (notebooks.isEmpty)
    const WorkspaceChoice('local', 'دفتر حسابي', 'ابدأ دفترًا على هذا الجهاز'),
];

/// The local notebook header can render this without initializing AuthController.
class WorkspaceSwitcherButton extends StatelessWidget {
  final String currentKind;
  final String? name, notebookId;
  final LocalLedgerStore? store;
  final bool enabled;
  const WorkspaceSwitcherButton({
    super.key,
    required this.currentKind,
    this.name,
    this.notebookId,
    this.store,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name?.trim().isNotEmpty == true
        ? name!.trim().characters.first
        : null;
    return Tooltip(
      message: 'تبديل الحساب',
      child: Material(
        color: AppColors.primaryContainer,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: enabled
              ? () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  backgroundColor: AppColors.backgroundLight,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                  ),
                  builder: (_) => _WorkspaceSwitcherSheet(
                    currentKind: currentKind,
                    notebookId: notebookId,
                    store: store ?? LocalLedgerStore.instance,
                  ),
                )
              : null,
          child: Semantics(
            button: true,
            label:
                'تبديل الحساب، ${switch (currentKind) {
                  'merchant' => 'حساب التاجر',
                  'customer' => 'حساب الزبون',
                  _ => 'الدفتر المحلي',
                }}',
            child: SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 17,
                      backgroundColor: AppColors.white,
                      child: initial == null
                          ? const Icon(
                              Icons.person_outline_rounded,
                              size: 21,
                              color: AppColors.primaryDark,
                            )
                          : Text(
                              initial,
                              style: const TextStyle(
                                color: AppColors.primaryDark,
                                fontWeight: FontWeight.w800,
                                fontSize: 17,
                              ),
                            ),
                    ),
                    const Icon(
                      Icons.expand_more_rounded,
                      size: 19,
                      color: AppColors.primaryDark,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceSwitcherSheet extends ConsumerStatefulWidget {
  final String currentKind;
  final String? notebookId;
  final LocalLedgerStore store;
  const _WorkspaceSwitcherSheet({
    required this.currentKind,
    this.notebookId,
    required this.store,
  });
  @override
  ConsumerState<_WorkspaceSwitcherSheet> createState() =>
      _WorkspaceSwitcherSheetState();
}

class _WorkspaceSwitcherSheetState
    extends ConsumerState<_WorkspaceSwitcherSheet> {
  List<JsonMap>? _notebooks;
  String? _error;
  bool _busy = false;
  bool _loadingNotebooks = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loadingNotebooks = true;
      _error = null;
    });
    try {
      final rows = await widget.store.notebooks();
      if (!mounted) return;
      setState(() {
        _notebooks = rows;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'تعذر قراءة الحسابات المحفوظة. حاول مجددًا.');
      }
    } finally {
      if (mounted) setState(() => _loadingNotebooks = false);
    }
    // A damaged notebook must not prevent opening an available account.
    if (mounted && SupabaseConfig.cloudReady) {
      try {
        final auth = ref.read(authControllerProvider.notifier);
        await auth.localReady;
        if (mounted) await auth.refreshLocalBusinessAccess();
      } catch (_) {
        if (mounted) {
          setState(
            () => _error =
                'تعذر تحديث الحسابات المحفوظة. افتح إدارة الحسابات لإعادة المحاولة.',
          );
        }
      }
    }
  }

  Future<void> _select(WorkspaceChoice choice) async {
    if (_busy) return;
    if (choice.matches(widget.currentKind, widget.notebookId)) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      final auth = SupabaseConfig.cloudReady
          ? ref.read(authControllerProvider.notifier)
          : null;
      final route = await prepareWorkspaceNavigation(
        auth: auth,
        kind: choice.kind,
        notebook: choice.notebook,
        store: widget.store,
      );
      if (!mounted) return;
      navigator.pushNamedAndRemoveUntil(route, (_) => false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error is StateError
              ? error.message.toString()
              : 'تعذر فتح الحساب. حاول مجددًا.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = SupabaseConfig.cloudReady
        ? ref.watch(authControllerProvider)
        : const AuthState();
    final choices = availableWorkspaces(
      auth,
      _notebooks ?? [],
    ).where((choice) => choice.kind != 'local' || _notebooks != null).toList();
    return PopScope(
      canPop: !_busy,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.borderLight,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'تبديل الحساب',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  auth.displayName ?? 'حساباتك ودفاترك',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 20),
                if (_loadingNotebooks) const LinearProgressIndicator(),
                if (choices.isNotEmpty)
                  WorkspaceChoiceList(
                    choices: choices,
                    currentKind: widget.currentKind,
                    notebookId: widget.notebookId,
                    busy: _busy,
                    onSelect: _select,
                  ),
                if (_error != null) ...[
                  Text(_error!, style: const TextStyle(color: AppColors.error)),
                  if (_notebooks == null && !_loadingNotebooks)
                    TextButton(
                      onPressed: _load,
                      child: const Text('إعادة المحاولة'),
                    ),
                ],
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () {
                          final navigator = Navigator.of(context);
                          navigator.pop();
                          navigator.pushNamed(
                            auth.hasLocalAccess
                                ? AppRoutes.workspaces
                                : AppRoutes.login,
                          );
                        },
                  icon: Icon(
                    auth.hasLocalAccess
                        ? Icons.dashboard_customize_outlined
                        : Icons.login_rounded,
                    size: 19,
                  ),
                  label: Text(
                    auth.hasLocalAccess
                        ? 'إدارة الحسابات والدفاتر'
                        : 'تسجيل الدخول إلى حسابي',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WorkspaceChoiceList extends StatelessWidget {
  final List<WorkspaceChoice> choices;
  final String currentKind;
  final String? notebookId;
  final bool busy;
  final ValueChanged<WorkspaceChoice> onSelect;
  const WorkspaceChoiceList({
    super.key,
    required this.choices,
    required this.currentKind,
    this.notebookId,
    this.busy = false,
    required this.onSelect,
  });
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final choice in choices)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: choice.matches(currentKind, notebookId)
                ? AppColors.primaryContainer
                : AppColors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(
                color: choice.matches(currentKind, notebookId)
                    ? AppColors.primary
                    : AppColors.borderLight,
              ),
            ),
            child: ListTile(
              key: ValueKey(
                'workspace-${choice.kind}-${choice.notebook?['id'] ?? ''}',
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 8,
              ),
              leading: Icon(choice.icon, color: AppColors.primaryDark),
              title: Text(
                choice.title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                choice.matches(currentKind, notebookId)
                    ? '${choice.subtitle} • الحالي'
                    : choice.subtitle,
              ),
              trailing: Icon(
                choice.matches(currentKind, notebookId)
                    ? Icons.check_circle_rounded
                    : Icons.chevron_left_rounded,
                color: choice.matches(currentKind, notebookId)
                    ? AppColors.primary
                    : AppColors.textMuted,
              ),
              onTap: busy ? null : () => onSelect(choice),
            ),
          ),
        ),
    ],
  );
}
