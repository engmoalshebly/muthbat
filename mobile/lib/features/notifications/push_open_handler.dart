import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/router/app_routes.dart';
import '../../core/config/supabase_config.dart';
import '../../core/services/push_notification_service.dart';
import '../auth/presentation/controllers/auth_controller.dart';
import 'notification_repository.dart';

class NotificationRouteObserver extends NavigatorObserver {
  String? current;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    current = route.settings.name;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    current = previousRoute?.settings.name;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    current = newRoute?.settings.name;
  }
}

class PushOpenHandler extends ConsumerStatefulWidget {
  const PushOpenHandler({
    super.key,
    required this.navigatorKey,
    required this.observer,
    required this.child,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final NotificationRouteObserver observer;
  final Widget child;
  @override
  ConsumerState<PushOpenHandler> createState() => _PushOpenHandlerState();
}

class _PushOpenHandlerState extends ConsumerState<PushOpenHandler> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    PushNotificationService.instance.opened.addListener(_schedule);
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (PushNotificationService.instance.opened.value != null) {
      _timer = Timer(const Duration(milliseconds: 500), _drain);
    }
  }

  Future<void> _drain() async {
    if (!mounted || !SupabaseConfig.cloudReady) return;
    final push = PushNotificationService.instance;
    final data = push.opened.value;
    if (data == null) return;
    final auth = ref.read(authControllerProvider);
    if (auth.userId != null && auth.userId != data['user_id']) {
      push.opened.value = null;
      return;
    }
    final navigator = widget.navigatorKey.currentState;
    if (!auth.hasLocalAccess ||
        auth.userId == null ||
        navigator == null ||
        [
          null,
          AppRoutes.splash,
          AppRoutes.welcome,
          AppRoutes.login,
        ].contains(widget.observer.current)) {
      _schedule();
      return;
    }
    push.opened.value = null;
    try {
      await NotificationRepository().cachePush(auth.userId!, data);
    } catch (_) {
      /* The server copy can be loaded when connectivity returns. */
    }
    if (!mounted || ref.read(authControllerProvider).userId != auth.userId) {
      return;
    }
    navigator.pushNamed(
      AppRoutes.notifications,
      arguments: data['notification_id'],
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    PushNotificationService.instance.opened.removeListener(_schedule);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
