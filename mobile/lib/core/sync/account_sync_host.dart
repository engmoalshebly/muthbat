import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../database/app_database.dart';
import '../config/supabase_config.dart';
import '../security/cloud_session.dart';
import '../services/push_notification_service.dart';
import '../../features/auth/presentation/controllers/auth_controller.dart';
import '../../features/customer/data/customer_repository.dart';
import '../../features/customer/data/customer_disputes_repository.dart';
import '../../features/notifications/notification_repository.dart';

/// Account-wide synchronization stays alive when switching workspaces.
/// Screens can open local projections without depending on this worker.
class AccountSyncHost extends ConsumerStatefulWidget {
  const AccountSyncHost({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<AccountSyncHost> createState() => _AccountSyncHostState();
}

class _AccountSyncHostState extends ConsumerState<AccountSyncHost>
    with WidgetsBindingObserver {
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  bool _busy = false;
  bool _requested = false;
  DateTime? _last;
  String? _lastOwner;

  @override
  void initState() {
    super.initState();
    if (!SupabaseConfig.cloudReady) return;
    WidgetsBinding.instance.addObserver(this);
    PushNotificationService.instance.changes.addListener(_request);
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) _request();
    });
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => _request());
    WidgetsBinding.instance.addPostFrameCallback((_) => _request());
  }

  void _request() {
    if (!mounted || !SupabaseConfig.cloudReady) return;
    _requested = true;
    if (!_busy) unawaited(_sync());
  }

  Future<void> _sync() async {
    if (_busy || !mounted) return;
    final auth = ref.read(authControllerProvider);
    final owner = auth.userId;
    if (!auth.hasLocalAccess ||
        owner == null ||
        AppDatabase.instance.accountId != owner) {
      return;
    }
    final client = Supabase.instance.client;
    if (!canUseCloudSession(client.auth.currentSession, owner)) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    _busy = true;
    _requested = false;
    bool current() =>
        mounted &&
        ref.read(authControllerProvider).userId == owner &&
        AppDatabase.instance.accountId == owner &&
        canUseCloudSession(client.auth.currentSession, owner);
    try {
      final results = await Connectivity().checkConnectivity();
      if (!current() || results.every((r) => r == ConnectivityResult.none)) {
        return;
      }
      // Independent streams: a failure to refresh an inbox cannot block finance.
      await Future.wait([
        () async {
          try {
            await NotificationRepository().sync(owner, client);
          } catch (e) {
            debugPrint('[AccountSync] inbox deferred: $e');
          }
        }(),
        () async {
          try {
            final repo = CustomerRepository();
            await repo.flushOutbox();
            if (!current()) return;
            try {
              await CustomerDisputesRepository().sync(owner);
            } catch (e) {
              debugPrint('[AccountSync] disputes deferred: $e');
            }
            try {
              await repo.refreshPhoneLinks();
            } catch (_) {}
            if (!current()) return;
            final home = await repo.fetchHomeSnapshot();
            if (!current()) return;
            await repo.syncLocalLedgers(home);
          } catch (e) {
            debugPrint('[AccountSync] customer refresh deferred: $e');
          }
        }(),
      ]);
      if (!current()) return;
      // Permission validation runs independently of local navigation.
      if (_lastOwner != owner ||
          _last == null ||
          DateTime.now().difference(_last!) > const Duration(minutes: 5)) {
        await ref
            .read(authControllerProvider.notifier)
            .refreshCloudBusinessAccess();
        if (current()) {
          _lastOwner = owner;
          _last = DateTime.now();
        }
      }
    } catch (e) {
      debugPrint('[AccountSync] deferred: $e');
    } finally {
      _busy = false;
      if (_requested && mounted) scheduleMicrotask(_request);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _request();
  }

  @override
  Widget build(BuildContext context) {
    if (!SupabaseConfig.cloudReady) return widget.child;
    ref.listen(
      authControllerProvider.select((s) => (s.userId, s.status)),
      (_, next) =>
          WidgetsBinding.instance.addPostFrameCallback((_) => _request()),
    );
    return widget.child;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _connectivity?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    PushNotificationService.instance.changes.removeListener(_request);
    super.dispose();
  }
}
