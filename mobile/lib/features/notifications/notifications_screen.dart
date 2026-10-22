import 'dart:async';
import '../../core/database/app_database.dart';
import '../../core/sync/sync_engine.dart';
import 'notification_repository.dart';
import '../customer/data/customer_local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../app/router/app_routes.dart';
import '../../core/config/supabase_config.dart';
import '../../core/services/push_notification_service.dart';
import '../customer/presentation/screens/customer_account_ledger_screen.dart';
import '../customer/presentation/screens/customer_entry_details_screen.dart';
import '../customer/presentation/screens/customer_disputes_screen.dart';
import '../auth/presentation/controllers/auth_controller.dart';
import '../auth/presentation/customer_entry_mode.dart';
import '../auth/presentation/workspace_preference.dart';
import '../merchant/data/models/dispute_model.dart';
import '../merchant/data/models/business_customer_model.dart';

class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key, required this.workspace});
  final String workspace;
  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell>
    with WidgetsBindingObserver {
  int _count = 0;
  RealtimeChannel? _channel;
  late final String? _owner = AppDatabase.instance.accountId;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PushNotificationService.instance.changes.addListener(_refresh);
    NotificationRepository.changes.addListener(_refresh);
    if (SupabaseConfig.cloudReady) {
      final client = Supabase.instance.client;
      final user = client.auth.currentUser;
      if (user != null) {
        _channel = client
            .channel('notice-bell-${identityHashCode(this)}')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'notifications',
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'user_id',
                value: user.id,
              ),
              callback: (_) => PushNotificationService.instance.changes.value++,
            )
            .subscribe();
      }
    }
    _refresh();
  }

  Future<void> _refresh() async {
    final user = _owner;
    if (user == null) return;
    try {
      final result = await NotificationRepository().unread(
        user,
        widget.workspace,
      );
      if (mounted && AppDatabase.instance.accountId == user) {
        setState(() => _count = result);
      }
    } catch (_) {
      /* The inbox exposes connection errors with a retry action. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PushNotificationService.instance.changes.removeListener(_refresh);
    NotificationRepository.changes.removeListener(_refresh);
    if (_channel != null) Supabase.instance.client.removeChannel(_channel!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'الإشعارات',
    icon: Badge(
      isLabelVisible: _count > 0,
      label: Text(_count > 99 ? '99+' : '$_count'),
      child: const Icon(Icons.notifications_outlined),
    ),
    onPressed: () async {
      await Navigator.pushNamed(
        context,
        AppRoutes.notifications,
        arguments: {'workspace': widget.workspace},
      );
      _refresh();
    },
  );
}

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({
    super.key,
    this.initialId,
    this.workspace = 'auto',
  });
  final String? initialId;
  final String workspace;
  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen>
    with WidgetsBindingObserver {
  final _client = Supabase.instance.client;
  late final String? _owner = AppDatabase.instance.accountId;
  final _repository = NotificationRepository();
  String get _workspace =>
      widget.workspace == 'auto' ? 'merchant' : widget.workspace;
  bool get _current =>
      mounted && _owner != null && AppDatabase.instance.accountId == _owner;
  int _loadVersion = 0;
  List<Map<String, dynamic>> _rows = [];
  String? _error;
  bool _loading = true, _more = true;
  RealtimeChannel? _channel;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PushNotificationService.instance.changes.addListener(_reload);
    NotificationRepository.changes.addListener(_reload);
    _channel = _client
        .channel('notice-inbox-${identityHashCode(this)}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: _owner ?? '',
          ),
          callback: (_) => PushNotificationService.instance.changes.value++,
        )
        .subscribe();
    _load().then((_) {
      if (widget.initialId != null && mounted) _openId(widget.initialId!);
    });
  }

  void _reload() {
    unawaited(_load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PushNotificationService.instance.changes.removeListener(_reload);
    NotificationRepository.changes.removeListener(_reload);
    if (_channel != null) _client.removeChannel(_channel!);
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (!_current) return;
    final version = ++_loadVersion;
    final offset = more ? _rows.length : 0;
    final limit = more ? 40 : (_rows.length > 40 ? _rows.length : 40);
    try {
      final result = await _repository.list(
        _owner!,
        _workspace,
        offset: offset,
        limit: limit + 1,
      );
      if (!_current || version != _loadVersion) return;
      setState(() {
        final page = result.take(limit).toList();
        final unique = (more ? _rows : <Map<String, dynamic>>[])
            .map((n) => n['id'])
            .toSet();
        _rows = [
          ...(more ? _rows : <Map<String, dynamic>>[]),
          ...page.where((n) => unique.add(n['id'])),
        ];
        _more = result.length > limit;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'تعذر تحميل الإشعارات. تحقق من الاتصال وأعد المحاولة.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _openId(String id) async {
    try {
      var row = await _repository.find(_owner!, id);
      if (!_current) return;
      if (row == null) {
        row = await _client
            .from('notifications')
            .select()
            .eq('id', id)
            .eq('user_id', _owner)
            .maybeSingle()
            .timeout(const Duration(seconds: 12));
        if (!_current) return;
        if (row != null) await _repository.merge(_owner, [row]);
      }
      if (row != null && _current) await _open(row);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر فتح الإشعار. أعد المحاولة.')),
        );
      }
    }
  }

  Map<String, dynamic> _notificationData(Map<String, dynamic> row) {
    final data = row['data'];
    return data is Map ? Map<String, dynamic>.from(data) : const {};
  }

  /// Resolves the account again through RLS instead of trusting a push payload.
  Future<bool> _openCustomerAccount(
    Map<String, dynamic> row, {
    Map<String, dynamic>? entry,
  }) async {
    final data = _notificationData(row);
    if (data['workspace'] != 'customer') return false;

    final businessCustomerId =
        data['business_customer_id']?.toString() ??
        entry?['business_customer_id']?.toString();
    if (businessCustomerId == null || businessCustomerId.isEmpty) return false;
    final currency =
        data['currency']?.toString() ?? entry?['currency_code']?.toString();
    try {
      final summary = await CustomerLocalStore().summary(
        _owner!,
        businessCustomerId,
        currency,
      );
      if (summary == null || !mounted || !_current) {
        return false;
      }
      await Navigator.of(context).push(
        AppRoutes.accountPage(
          builder: (_) => CustomerAccountLedgerScreen(
            summary: summary,
            focusEntryId:
                entry?['id']?.toString() ??
                (row['entity_type'] == 'ledger_entry'
                    ? row['entity_id']?.toString()
                    : null),
          ),
        ),
      );
      return true;
    } catch (_) {
      // The notification can still be opened if this relationship changed.
      return false;
    }
  }

  Future<void> _open(Map<String, dynamic> row) async {
    final owner = _owner;
    if (owner == null || !_current) return;
    try {
      final targetWorkspace = _notificationData(row)['workspace']?.toString();
      if (targetWorkspace != null &&
          targetWorkspace != widget.workspace &&
          targetWorkspace != 'auto' &&
          (targetWorkspace == 'customer' || targetWorkspace == 'merchant')) {
        await CustomerEntryMode.remember(owner, targetWorkspace == 'customer');
        await WorkspacePreference.save(owner, targetWorkspace);
        if (targetWorkspace == 'customer') {
          await ref
              .read(authControllerProvider.notifier)
              .prepareCustomerWorkspace();
        } else {
          await ref
              .read(authControllerProvider.notifier)
              .refreshLocalBusinessAccess();
        }
        if (!mounted || !_current) return;
        final destination = targetWorkspace == 'customer'
            ? AppRoutes.customerHome
            : AppRoutes.merchantHome;
        Navigator.pushNamedAndRemoveUntil(context, destination, (_) => false);
        Navigator.pushNamed(
          context,
          AppRoutes.notifications,
          arguments: {
            'workspace': targetWorkspace,
            'notificationId': row['id'],
          },
        );
        return;
      }
      await _repository.markRead(owner, _workspace, id: row['id'] as String);
      PushNotificationService.instance.changes.value++;
      if (!_current) return;
      if (row['entity_type'] == 'dispute' &&
          _notificationData(row)['workspace'] == 'customer') {
        if (!mounted) return;
        await Navigator.of(context).push(
          AppRoutes.accountPage(
            builder: (_) =>
                CustomerDisputesScreen(disputeId: row['entity_id']?.toString()),
          ),
        );
        return;
      }
      if (await _openCustomerAccount(row)) return;
      if (!_current) return;
      if (_notificationData(row)['workspace'] == 'merchant') {
        final business = ref.read(authControllerProvider).activeBusinessId;
        final db = await AppDatabase.instance.database;
        if (!_current) return;
        if (business != null && row['entity_type'] == 'dispute') {
          var disputes = await db.query(
            'local_disputes',
            where: 'id=? AND business_id=?',
            whereArgs: [row['entity_id'], business],
            limit: 1,
          );
          if (disputes.isEmpty) {
            await SyncEngine.instance.triggerSync();
            if (!mounted || !_current) return;
            disputes = await db.query(
              'local_disputes',
              where: 'id=? AND business_id=?',
              whereArgs: [row['entity_id'], business],
              limit: 1,
            );
          }
          if (!mounted || !_current) return;
          if (disputes.isNotEmpty) {
            await Navigator.pushNamed(
              context,
              AppRoutes.disputeDetail,
              arguments: DisputeModel.fromMap(disputes.single),
            );
            return;
          }
          if (!mounted || !_current) return;
          await Navigator.pushNamed(context, AppRoutes.disputesList);
          return;
        }
        if (row['entity_type'] == 'dispute') {
          if (!mounted || !_current) return;
          await Navigator.pushNamed(context, AppRoutes.disputesList);
          return;
        }
        final relationship = _notificationData(row)['business_customer_id'];
        if (business != null && relationship is String) {
          final customers = await db.query(
            'local_business_customers',
            where: 'id=? AND business_id=?',
            whereArgs: [relationship, business],
            limit: 1,
          );
          if (!mounted || !_current) return;
          if (customers.isNotEmpty) {
            await Navigator.pushNamed(
              context,
              AppRoutes.customerLedger,
              arguments: BusinessCustomerModel.fromMap(customers.single),
            );
            return;
          }
        }
      }
      final localEntry = row['entity_type'] == 'ledger_entry'
          ? await CustomerLocalStore().entry(owner, row['entity_id'].toString())
          : null;
      if (!mounted || !_current) return;
      if (localEntry != null) {
        await Navigator.of(context).push(
          AppRoutes.accountPage(
            builder: (_) => CustomerEntryDetailsScreen(
              businessName: localEntry['business_name']?.toString() ?? 'المحل',
              entry: localEntry,
              ownerId: owner,
            ),
          ),
        );
        return;
      }
      // The notification itself always opens locally. Cloud-only dispute
      // details remain available through the destination account after sync.
      if (!mounted || !_current) return;
      if (row['entity_type'] == 'link_request') {
        await Navigator.pushNamed(context, AppRoutes.customerHome);
        return;
      }
      await _showNotice(row);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر فتح الإشعار المحفوظ. أعد المحاولة.'),
          ),
        );
      }
    }
  }

  Future<void> _showNotice(Map<String, dynamic> row) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                row['title'] as String,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(row['body'] as String),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () {
                  Navigator.pop(sheet);
                  Navigator.pushNamed(
                    context,
                    _notificationData(row)['workspace'] == 'merchant'
                        ? AppRoutes.merchantHome
                        : AppRoutes.customerHome,
                  );
                },
                child: const Text('فتح الحساب ومراجعة التفاصيل'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('الإشعارات'),
      actions: [
        IconButton(
          tooltip: 'إعدادات الإشعارات',
          icon: const Icon(Icons.tune),
          onPressed: () => Navigator.of(context).push(
            AppRoutes.accountPage(
              builder: (_) => const NotificationSettingsScreen(),
            ),
          ),
        ),
        IconButton(
          tooltip: 'تحديد الكل كمقروء',
          icon: const Icon(Icons.done_all),
          onPressed: () async {
            try {
              await _repository.markRead(_owner!, _workspace);
              _reload();
              PushNotificationService.instance.changes.value++;
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('تعذر حفظ حالة القراءة.')),
                );
              }
            }
          },
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: () async {
              PushNotificationService.instance.changes.value++;
              await _load();
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  ListTile(
                    title: Text(_error!),
                    trailing: TextButton(
                      onPressed: _reload,
                      child: const Text('إعادة المحاولة'),
                    ),
                  ),
                if (_rows.isEmpty && _error == null)
                  const Padding(
                    padding: EdgeInsets.all(48),
                    child: Column(
                      children: [
                        Icon(Icons.notifications_none, size: 56),
                        SizedBox(height: 16),
                        Text('لا توجد إشعارات بعد'),
                      ],
                    ),
                  ),
                ..._rows.map(
                  (row) => Card(
                    child: ListTile(
                      leading: Icon(
                        row['read_at'] == null
                            ? Icons.notifications_active
                            : Icons.notifications_none,
                        color: row['read_at'] == null
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      trailing: const Icon(Icons.chevron_left),
                      title: Text(row['title'] as String),
                      subtitle: Text(
                        '${row['body']}\n${DateTime.tryParse(row['created_at'] as String)?.toLocal().toString().substring(0, 16) ?? ''}',
                      ),
                      isThreeLine: true,
                      onTap: () => _open(row),
                    ),
                  ),
                ),
                if (_more)
                  TextButton(
                    onPressed: () => _load(more: true),
                    child: const Text('عرض المزيد'),
                  ),
              ],
            ),
          ),
  );
}

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});
  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  late final String? _owner = AppDatabase.instance.accountId;
  final _repository = NotificationRepository();
  Map<String, dynamic>? _prefs;
  bool _saving = false;
  String? _error;
  static const _labels = {
    'push_enabled': 'إشعارات الهاتف',
    'financial_enabled': 'الديون والسداد والقيود',
    'disputes_enabled': 'الاعتراضات والردود',
    'reminders_enabled': 'تذكيرات الاستحقاق',
  };
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final row = await _repository.preferences(_owner!);
      if (mounted && AppDatabase.instance.accountId == _owner) {
        setState(() => _prefs = row);
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'تعذر تحميل الإعدادات.');
    }
  }

  Future<void> _save(String key, bool value) async {
    if (_saving || AppDatabase.instance.accountId != _owner) return;
    setState(() => _saving = true);
    try {
      await _repository.savePreference(_owner!, key, value);
      if (mounted && AppDatabase.instance.accountId == _owner) {
        setState(() => _prefs![key] = value);
      }
      PushNotificationService.instance.changes.value++;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر حفظ الإعداد. أعد المحاولة.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('إعدادات الإشعارات')),
    body: _prefs == null
        ? Center(
            child: _error == null
                ? const CircularProgressIndicator()
                : TextButton(
                    onPressed: _load,
                    child: Text('$_error إعادة المحاولة'),
                  ),
          )
        : ListView(
            children: [
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'تبقى جميع الإشعارات محفوظة داخل حسابك. تتحكم الخيارات التالية بتنبيهات الهاتف. يمكنك إدارة الصوت والإذن من إعدادات أندرويد.',
                ),
              ),
              for (final item in _labels.entries)
                SwitchListTile(
                  title: Text(item.value),
                  value: _prefs![item.key] as bool,
                  onChanged: _saving ? null : (value) => _save(item.key, value),
                ),
            ],
          ),
  );
}
