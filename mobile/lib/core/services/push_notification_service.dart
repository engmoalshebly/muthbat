import 'dart:async';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../firebase_options.dart';
import '../database/app_database.dart';
import '../../features/notifications/notification_repository.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Android displays the notification payload; never display it twice.
}

class PushNotificationService with WidgetsBindingObserver {
  PushNotificationService._();
  static final instance = PushNotificationService._();
  static const channelId = 'muthbat_updates';
  static const _channel = AndroidNotificationChannel(
    channelId,
    'إشعارات الحساب',
    description: 'الديون والسداد والاعتراضات وطلبات الربط',
    importance: Importance.high,
  );
  final _local = FlutterLocalNotificationsPlugin();
  final opened = ValueNotifier<Map<String, dynamic>?>(null);
  final changes = ValueNotifier<int>(0);
  bool _initialized = false;
  bool _signingOut = false;
  String? _token;
  Future<void> _syncQueue = Future.value();
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> init() async {
    if (_initialized || !supported) return;
    try {
      await _local.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_notification'),
        ),
        onDidReceiveNotificationResponse: (response) {
          try {
            _open(
              Map<String, dynamic>.from(jsonDecode(response.payload ?? '{}')),
            );
          } catch (_) {}
        },
      );
      await _local
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(_channel);
      final launch = await _local.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        try {
          _open(
            Map<String, dynamic>.from(
              jsonDecode(launch!.notificationResponse?.payload ?? '{}'),
            ),
          );
        } catch (_) {}
      }
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      FirebaseMessaging.onMessage.listen((message) async {
        final user = Supabase.instance.client.auth.currentUser;
        if (user == null || message.data['user_id'] != user.id) return;
        final notice = message.notification;
        if (notice == null) return;
        final data = _messageData(message);
        try {
          if (AppDatabase.instance.accountId == user.id) {
            await NotificationRepository().cachePush(user.id, data);
          }
        } catch (e) {
          debugPrint('[Push] local persistence deferred: $e');
        }
        if (Supabase.instance.client.auth.currentUser?.id != user.id ||
            AppDatabase.instance.accountId != user.id ||
            _signingOut) {
          return;
        }
        changes.value++;
        await _local.show(
          id:
              (message.data['notification_id'] ?? message.messageId ?? '')
                  .hashCode &
              0x7fffffff,
          title: notice.title,
          body: notice.body,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              channelId,
              'إشعارات الحساب',
              importance: Importance.high,
              priority: Priority.high,
              icon: 'ic_stat_notification',
              visibility: NotificationVisibility.private,
            ),
          ),
          payload: jsonEncode(data),
        );
      });
      FirebaseMessaging.onMessageOpenedApp.listen(
        (message) => _open(_messageData(message)),
      );
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _open(_messageData(initial));
      // HTTP v1 sends to registration tokens; keep the token API until the
      // backend migrates to Firebase's newer installation-ID send protocol.
      // ignore: deprecated_member_use
      FirebaseMessaging.instance.onTokenRefresh.listen((token) {
        _token = token;
        unawaited(syncDeviceToken());
      });
      Supabase.instance.client.auth.onAuthStateChange.listen((event) {
        if (event.event == AuthChangeEvent.signedIn ||
            event.event == AuthChangeEvent.tokenRefreshed) {
          _signingOut = false;
          unawaited(syncDeviceToken());
        } else if (event.event == AuthChangeEvent.signedOut) {
          opened.value = null;
          unawaited(_local.cancelAll());
        }
      });
      _initialized = true;
      WidgetsBinding.instance.addObserver(this);
      unawaited(syncDeviceToken());
    } catch (error) {
      debugPrint('[Push] Initialization failed: $error');
    }
  }

  void _open(Map<String, dynamic> data) {
    if (data['notification_id'] is String && data['user_id'] is String) {
      opened.value = data;
    }
  }

  Map<String, dynamic> _messageData(RemoteMessage message) => {
    ...message.data,
    '_title': message.notification?.title ?? 'إشعار الحساب',
    '_body': message.notification?.body ?? '',
    '_sent_at': (message.sentTime ?? DateTime.now()).toUtc().toIso8601String(),
  };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(syncDeviceToken());
  }

  Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString('muthbat_push_device_id');
    if (existing != null) return existing;
    final id = const Uuid().v4();
    await prefs.setString('muthbat_push_device_id', id);
    return id;
  }

  Future<void> syncDeviceToken() {
    if (!supported) return Future.value();
    return _syncQueue = _syncQueue.then((_) async {
      final client = Supabase.instance.client;
      final user = client.auth.currentUser;
      if (user == null || _signingOut) return;
      try {
        final permission = await FirebaseMessaging.instance.requestPermission();
        if (permission.authorizationStatus != AuthorizationStatus.authorized) {
          return;
        }
        // ignore: deprecated_member_use
        _token = await FirebaseMessaging.instance.getToken();
        if (_token == null ||
            _signingOut ||
            client.auth.currentUser?.id != user.id) {
          return;
        }
        final device = await _deviceId();
        if (_signingOut || client.auth.currentUser?.id != user.id) return;
        await client
            .rpc(
              'register_android_push_token',
              params: {'p_device_id': device, 'p_token': _token},
            )
            .timeout(const Duration(seconds: 15));
      } catch (error) {
        debugPrint('[Push] Device registration failed: $error');
      }
    });
  }

  // Called before signOut, while RLS can still authorize the update.
  Future<void> deactivateDeviceToken() async {
    if (!supported) return;
    _signingOut = true;
    await _syncQueue;
    try {
      if (_token != null) {
        await Supabase.instance.client
            .from('device_push_tokens')
            .update({'is_active': false})
            .eq('push_token', _token!)
            .timeout(const Duration(seconds: 10));
      }
    } catch (error) {
      debugPrint('[Push] Token deactivation failed: $error');
    }
    try {
      // ignore: deprecated_member_use
      await FirebaseMessaging.instance.deleteToken().timeout(
        const Duration(seconds: 10),
      );
    } catch (error) {
      debugPrint('[Push] Token deletion failed: $error');
    }
    _token = null;
    opened.value = null;
    await _local.cancelAll();
  }
}
