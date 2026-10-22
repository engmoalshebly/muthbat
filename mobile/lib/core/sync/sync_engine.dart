import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../security/cloud_session.dart';
import 'sync_policy.dart';
import 'business_logo_upload.dart';

enum SyncState { idle, syncing, synced, offline, error }

/// تصنيف خطأ المزامنة: دائم (dead_letter فوراً) / مؤقت (backoff) / غامض.
enum SyncErrorClass { permanent, transient, unknown }

class SyncErrorClassification {
  final SyncErrorClass kind;
  final String message;
  final String? code;

  const SyncErrorClassification(this.kind, this.message, {this.code});
}

class SyncProgress {
  final SyncState state;
  final int pendingCount;
  final int failedCount;
  final int deadLetterCount;
  final String? lastMessage;
  final DateTime? lastSyncAt;
  final bool dataChanged;

  const SyncProgress({
    this.state = SyncState.idle,
    this.pendingCount = 0,
    this.failedCount = 0,
    this.deadLetterCount = 0,
    this.lastMessage,
    this.lastSyncAt,
    this.dataChanged = false,
  });
}

/// الحد الأقصى لمحاولات الإرسال قبل التحويل إلى dead_letter.
const int kMaxSyncAttempts = 8;

/// الحد الأقصى لمحاولات الأخطاء غامضة التصنيف (احتياطي).
const int kMaxUnknownErrorAttempts = 3;

/// تصنيف أخطاء المزامنة إلى دائم/مؤقت/غامض (خطة 05 — سادساً).
///
/// دائم: PGRST202 (دالة غير موجودة)، HTTP 4xx، errcodes 42501/22023/55000/23505،
/// ورسائل الحراسة المالية — dead_letter فوراً بلا إعادة آلية.
/// مؤقت: أخطاء الشبكة/المهلة/429/5xx/23503 (اعتمادية لم تُزامن) — backoff أسّي.
/// غامض: أي خطأ آخر — يُعامل كمؤقت لكن يُحوَّل dead_letter بعد 3 محاولات.
SyncErrorClassification classifySyncError(Object error) {
  if (error is PostgrestException) {
    final code = error.code ?? '';
    final message = error.message;

    const permanentCodes = {
      'PGRST202', // الدالة غير موجودة — إعادة المحاولة لن تفيد
      '42501', // Not authorized
      '22023', // validation
      '55000', // state
      '23505', // unique_violation
      '400', '401', '403', '404', '409', '422',
    };
    if (permanentCodes.contains(code)) {
      return SyncErrorClassification(
        SyncErrorClass.permanent,
        message,
        code: code,
      );
    }
    // 23503 foreign_key_violation: اعتمادية (عميل/قيد) لم تُزامن بعد — مؤقت
    if (code == '23503') {
      return SyncErrorClassification(
        SyncErrorClass.transient,
        message,
        code: code,
      );
    }
    if (_isPermanentGuardMessage(message)) {
      return SyncErrorClassification(
        SyncErrorClass.permanent,
        message,
        code: code,
      );
    }
    return SyncErrorClassification(SyncErrorClass.unknown, message, code: code);
  }

  if (error is FunctionException) {
    final status = error.status;
    final message = error.toString();
    {
      if (status == 429 || status >= 500) {
        return SyncErrorClassification(
          SyncErrorClass.transient,
          message,
          code: '$status',
        );
      }
      if (status >= 400 && status < 500) {
        return SyncErrorClassification(
          SyncErrorClass.permanent,
          message,
          code: '$status',
        );
      }
    }
    return SyncErrorClassification(SyncErrorClass.unknown, message);
  }

  if (error is AuthException) {
    // انتهاء الجلسة: عميل supabase_flutter يجددها تلقائياً — مؤقت
    return SyncErrorClassification(
      SyncErrorClass.transient,
      error.message,
      code: error.statusCode,
    );
  }

  if (error is SocketException ||
      error is TimeoutException ||
      error is HandshakeException) {
    return SyncErrorClassification(SyncErrorClass.transient, error.toString());
  }

  final text = error.toString();
  if (text.startsWith('unknown_command:') || _isPermanentGuardMessage(text)) {
    return SyncErrorClassification(SyncErrorClass.permanent, text);
  }
  if (text.contains('SocketException') ||
      text.contains('TimeoutException') ||
      text.contains('ClientException') ||
      text.contains('Connection refused') ||
      text.contains('Network is unreachable')) {
    return SyncErrorClassification(SyncErrorClass.transient, text);
  }
  return SyncErrorClassification(SyncErrorClass.unknown, text);
}

/// رسائل الحراسة المالية/التخويلية في الباكند = فشل دائم لا تفيد معه إعادة الإرسال.
bool _isPermanentGuardMessage(String message) {
  const patterns = [
    'Credit limit exceeded',
    'Payment exceeds current balance',
    'Entry already reversed',
    'Not authorized',
    'not a member',
    'invalid input syntax',
    'violates check constraint',
  ];
  for (final pattern in patterns) {
    if (message.contains(pattern)) return true;
  }
  return false;
}

/// محرك المزامنة الذاتية في الخلفية (Background Synchronization Engine)
///
/// دورة حياة الطابور: pending → syncing → (نجاح: تسوية المعرّف + حذف)
/// أو (خطأ مؤقت: failed + backoff أسّي 1د→30د حتى 8 محاولات)
/// أو (خطأ دائم: dead_letter فوراً بلا حذف صامت).
class SyncEngine with WidgetsBindingObserver {
  SyncEngine._()
    : _injectedClient = null,
      _isOnline = null,
      _now = DateTime.now;

  @visibleForTesting
  SyncEngine.forTesting({
    required SupabaseClient client,
    required Future<bool> Function() isOnline,
    DateTime Function()? now,
  }) : _injectedClient = client,
       _isOnline = isOnline,
       _now = now ?? DateTime.now;

  final SupabaseClient? _injectedClient;
  final Future<bool> Function()? _isOnline;
  final DateTime Function() _now;
  SupabaseClient get _client => _injectedClient ?? Supabase.instance.client;
  static final SyncEngine instance = SyncEngine._();

  static const _uuid = Uuid();
  static final _random = Random();

  final _progressController = StreamController<SyncProgress>.broadcast();
  Stream<SyncProgress> get progressStream => _progressController.stream;
  SyncProgress? _latestProgress;
  SyncProgress? get latestProgress => _latestProgress;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _periodicTimer;
  bool _isProcessing = false;
  bool _syncRequested = false;
  bool _paused = false;
  Completer<void>? _drained;

  Future<void> pauseAndDrain() async {
    _paused = true;
    _syncRequested = false;
    await _drained?.future;
    _latestProgress = null;
  }

  void resume() {
    _paused = false;
  }

  DateTime? _lastSyncAt;

  /// بدء الاستماع لشبكة الإنترنت والمزامنة الدورية
  void init() {
    WidgetsBinding.instance.addObserver(this);
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final isOnline = results.any((r) => r != ConnectivityResult.none);
      if (isOnline) {
        debugPrint(
          '[SyncEngine] Network restored. Triggering automatic sync...',
        );
        triggerSync();
      } else {
        _notify(SyncState.offline, 'لا يوجد اتصال بالإنترنت (العمل محلياً)');
      }
    });

    // مزامنة دورية كل 30 ثانية — تلتقط فقط العناصر المستحقة
    // (عناصر backoff/dead_letter لا تُرسل في كل جولة)
    _periodicTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      triggerSync();
    });
  }

  void dispose() {
    _paused = true;
    _syncRequested = false;
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySub?.cancel();
    _periodicTimer?.cancel();
    _progressController.close();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) triggerSync();
  }

  Future<void> _notify(
    SyncState state,
    String? message, {
    bool dataChanged = false,
  }) async {
    final accountId = AppDatabase.instance.accountId;
    if (accountId == null || _progressController.isClosed) return;
    Map<String, int> counts;
    try {
      counts = await AppDatabase.instance.getMutationStatusCounts();
    } catch (error) {
      // Reporting a sync failure must never throw a second unhandled error
      // when sign-out or account switching closes the cache concurrently.
      debugPrint('[SyncEngine] Progress unavailable: $error');
      return;
    }
    if (AppDatabase.instance.accountId != accountId ||
        _progressController.isClosed) {
      return;
    }
    final progress = SyncProgress(
      state: state,
      pendingCount:
          (counts['pending'] ?? 0) +
          (counts['syncing'] ?? 0) +
          (counts['failed'] ?? 0),
      failedCount: counts['failed'] ?? 0,
      deadLetterCount: counts['dead_letter'] ?? 0,
      lastMessage: message,
      lastSyncAt: _lastSyncAt,
      dataChanged: dataChanged,
    );
    _latestProgress = progress;
    _progressController.add(progress);
  }

  /// Returns true only after all required data pulls and pending work succeed.
  Future<bool> triggerSync() async {
    if (_paused) return false;
    if (_isProcessing) {
      // A save during a pull must not wait for the next periodic timer.
      _syncRequested = true;
      return false;
    }
    if (_client.auth.currentSession == null) {
      return false;
    }
    if (AppDatabase.instance.accountId != _client.auth.currentUser?.id) {
      return false;
    }
    final syncAccountId = AppDatabase.instance.accountId!;
    _syncRequested = false;
    _isProcessing = true;
    _drained = Completer<void>();

    try {
      final isOnline = _isOnline != null
          ? await _isOnline()
          : (await Connectivity().checkConnectivity()).any(
              (r) => r != ConnectivityResult.none,
            );
      if (!isOnline) {
        await _notify(
          SyncState.offline,
          'لا يوجد اتصال بالإنترنت (العمل محلياً)',
        );
        return false;
      }

      // An offline-expired access token is recoverable with the securely
      // persisted refresh token. Retry when connectivity returns rather than
      // requiring a password for every offline interval.
      if (_client.auth.currentSession?.isExpired == true) {
        await _client.auth.refreshSession().timeout(
          const Duration(seconds: 15),
        );
      }
      requireCloudSession(_client, syncAccountId);
      assertSyncAccount(
        expected: syncAccountId,
        current: AppDatabase.instance.accountId,
      );

      await _recoverDeploymentFailures(syncAccountId);
      final pendingCount = await AppDatabase.instance
          .getPendingMutationsCount();
      if (pendingCount > 0) {
        await _notify(
          SyncState.syncing,
          'جاري مزامنة $pendingCount عملية معلقة...',
        );
      } else {
        await _notify(SyncState.syncing, 'جاري جلب تحديثات الحساب...');
      }

      // 1. معالجة العمليات غير المرسلة في الطابور (Push Queue)
      await _processPendingMutations(syncAccountId);
      if (_paused) return false;

      // 2. سحب البيانات المحدثة من السحابة (Pull Updates)
      requireCloudSession(_client, syncAccountId);
      assertSyncAccount(
        expected: syncAccountId,
        current: AppDatabase.instance.accountId,
      );
      await _pullRemoteUpdates(syncAccountId);
      if (_paused) return false;

      final remaining = await AppDatabase.instance.getPendingMutationsCount();
      final deadLetter = await AppDatabase.instance.getDeadLetterCount();
      requireCloudSession(_client, syncAccountId);
      assertSyncAccount(
        expected: syncAccountId,
        current: AppDatabase.instance.accountId,
      );
      if (remaining == 0 && deadLetter == 0) {
        _lastSyncAt = _now();
        await _notify(
          SyncState.synced,
          'تمت المزامنة بنجاح وكل البيانات موثقة',
        );
        return true;
      } else if (deadLetter > 0) {
        await _notify(SyncState.error, '$deadLetter عملية تحتاج مراجعة');
      } else {
        await _notify(SyncState.idle, '$remaining عمليات متبقية');
      }
      return false;
    } catch (e) {
      debugPrint('[SyncEngine] Sync error: $e');
      final classification = classifySyncError(e);
      final message = e is AuthException
          ? 'انتهت جلسة الدخول. افتح حسابك وأعد المحاولة.'
          : classification.kind == SyncErrorClass.transient
          ? 'تعذر الاتصال حاليًا. بياناتك محفوظة محليًا وستُعاد المحاولة تلقائيًا.'
          : 'تعذرت المزامنة. راجع حالة العمليات المعلقة وحاول مجددًا.';
      await _notify(SyncState.error, message);
      return false;
    } finally {
      _isProcessing = false;
      _drained?.complete();
      _drained = null;
      final rerun = _syncRequested;
      _syncRequested = false;
      if (rerun &&
          !_paused &&
          AppDatabase.instance.accountId == syncAccountId) {
        unawaited(triggerSync());
      }
    }
  }

  // ==================== Push: إرسال الأوامر المعلقة ====================

  Future<void> _recoverDeploymentFailures(String owner) async {
    final store = AppDatabase.instance;
    final db = await store.database;
    final candidates = await db.rawQuery(
      '''SELECT q.id FROM offline_mutations_queue q
      WHERE q.status='dead_letter' AND (
        (q.command_type='add_dispute_message' AND q.last_error_code='PGRST202') OR
        (q.command_type='update_business_profile' AND q.last_error_code='42501'
          AND q.last_error LIKE '%permission denied for table businesses%'))
      AND NOT EXISTS(SELECT 1 FROM local_sync_state s
        WHERE s.key='contract-repair-20261022:'||q.client_request_id) LIMIT 1''',
    );
    if (candidates.isEmpty) return;
    try {
      final result = await _client
          .rpc('client_sync_contract')
          .timeout(const Duration(seconds: 8));
      requireCloudSession(_client, owner);
      assertSyncAccount(expected: owner, current: store.accountId);
      if (result is Map &&
          result['version'] == '20261022-profile-disputes-v1') {
        await store.recoverDeploymentContractFailures();
      }
    } catch (error) {
      // Keep durable failures visible until the server confirms deployment.
      debugPrint(
        '[SyncEngine] Contract recovery deferred: ${error.runtimeType}',
      );
    }
  }

  Future<void> _processPendingMutations(String syncAccountId) async {
    final client = _client;
    if (!canUseCloudSession(client.auth.currentSession, syncAccountId)) return;

    final db = AppDatabase.instance;

    // استرجاع العناصر العالقة في syncing بعد إغلاق مفاجئ سابق
    await db.recoverStuckSyncingMutations();

    final mutations = await db.getDueMutations(DateTime.now());

    for (final snapshot in mutations) {
      if (_paused) return;
      // Earlier commands may have rewritten this command's payload or blocked
      // it. Never dispatch a stale in-memory snapshot of the queue.
      final mutation = await db.getMutationByClientRequestId(
        snapshot['client_request_id'] as String,
      );
      if (mutation == null ||
          !['pending', 'failed'].contains(mutation['status'])) {
        continue;
      }
      requireCloudSession(_client, syncAccountId);
      assertSyncAccount(
        expected: syncAccountId,
        current: AppDatabase.instance.accountId,
      );
      final String clientRequestId = mutation['client_request_id'];
      final String commandType = mutation['command_type'];
      final int attemptCount =
          (mutation['attempt_count'] as num?)?.toInt() ?? 0;
      Map<String, dynamic> payload =
          jsonDecode(mutation['payload_json']) as Map<String, dynamic>;
      payload = await db.resolveMutationReferences(payload);
      if (commandType == 'mutate_customer_profile' &&
          payload['p_action'] == 'archive' &&
          await db.hasEarlierCustomerWork(
            payload['p_business_customer_id'] as String,
            (mutation['id'] as num).toInt(),
          )) {
        continue;
      }

      // قاعدة الاعتمادية: لا يُرسل أمر قبل نجاح الأمر الذي يعتمد عليه
      final dependsOn = mutation['depends_on_client_request_id'] as String?;
      if (dependsOn != null && dependsOn.isNotEmpty) {
        if (await db.hasMutation(dependsOn)) continue;
      }

      // حارس إضافي: أي معرّف محلي (cust-*/entry-*) غير مُسوَّى في الحمولة
      // يعني أن الاعتمادية لم تُزامن بعد — يُؤجَّل الإرسال لهذه الجولة
      if (await _hasUnresolvedLocalIds(payload)) continue;

      await db.markMutationSyncing(clientRequestId);

      try {
        if (commandType == 'customer_directory' ||
            commandType == 'pending_directory' ||
            commandType == 'add_business_customer') {
          payload['requestId'] = clientRequestId;
        }
        if (commandType == 'mutate_customer_profile') {
          payload['p_request_id'] = clientRequestId;
        }
        if (commandType == 'create_business') {
          payload['p_request_id'] = clientRequestId;
        }
        if (commandType == 'upload_business_logo') {
          payload['requestId'] = clientRequestId;
        }
        if (commandType == 'update_business_currencies_idempotent') {
          payload['p_request_id'] = clientRequestId;
        }
        final serverEntityId = await _dispatchCommand(
          client,
          commandType,
          payload,
        );
        requireCloudSession(_client, syncAccountId);
        assertSyncAccount(
          expected: syncAccountId,
          current: AppDatabase.instance.accountId,
        );
        await _reconcileSuccess(mutation, serverEntityId);
      } catch (error) {
        if (error is SyncAccountChanged || error is AuthException) rethrow;
        final classification = classifySyncError(error);
        final newAttemptCount = attemptCount + 1;
        debugPrint(
          '[SyncEngine] Mutation $clientRequestId failed '
          '(${classification.kind.name}, code=${classification.code}): '
          '${classification.message}',
        );

        final isDeadLetter =
            classification.kind == SyncErrorClass.permanent ||
            newAttemptCount >= kMaxSyncAttempts ||
            (classification.kind == SyncErrorClass.unknown &&
                newAttemptCount >= kMaxUnknownErrorAttempts);

        if (isDeadLetter) {
          await db.markMutationDeadLetter(
            clientRequestId,
            attemptCount: newAttemptCount,
            error: classification.message,
            errorCode: classification.code,
          );
          if (commandType == 'update_business_currencies_idempotent') {
            await db.rollbackRejectedBusinessCurrencies(
              payload['p_business_id'] as String,
              jsonEncode(payload['p_additional_currencies']),
              payload['previous'] as String,
            );
          }
        } else {
          await db.markMutationFailed(
            clientRequestId,
            attemptCount: newAttemptCount,
            error: classification.message,
            errorCode: classification.code,
            nextRetryAt: computeNextRetryAt(newAttemptCount),
          );
        }
      }
    }
  }

  /// Backoff أسّي: 2^(attempt-1) دقيقة بحد أقصى 30 دقيقة مع jitter ±20%
  /// (1د، 2د، 4د، 8د، 16د، 30د...) — نفس نمط الباكند للإشعارات.
  @visibleForTesting
  static DateTime computeNextRetryAt(int attemptCount, {DateTime? now}) {
    final exponent = (attemptCount - 1).clamp(0, 10);
    final baseMinutes = min(30, 1 << exponent);
    final jitterFactor = 0.8 + _random.nextDouble() * 0.4;
    final delayMs = (baseMinutes * 60 * 1000 * jitterFactor).round();
    return (now ?? DateTime.now()).add(Duration(milliseconds: delayMs));
  }

  /// فحص وجود معرّفات محلية غير مُسوَّاة في الحمولة (اعتمادية ضمنية).
  Future<bool> _hasUnresolvedLocalIds(Map<String, dynamic> payload) async {
    for (final item in payload.entries) {
      // هذا معرّف مرجعي للتسوية بعد نجاح إنشاء العميل، وليس FK يُرسل للخادم.
      if (item.key == 'localCustomerId') continue;
      final value = item.value;
      if (value is String &&
          (value.startsWith('cust-') ||
              value.startsWith('entry-') ||
              value.startsWith('biz-'))) {
        final serverId = await AppDatabase.instance.getServerId(value);
        if (serverId == null) return true;
      }
    }
    return false;
  }

  /// توجيه الأمر إلى RPC العام أو Edge Function حسب العقد الموحد.
  /// يعيد معرّف الكيان الخادمي عند توفره (لتسوية المعرّفات).
  Future<String?> _dispatchCommand(
    SupabaseClient client,
    String commandType,
    Map<String, dynamic> payload,
  ) async {
    switch (commandType) {
      case 'update_business_currencies_idempotent':
        final saved = await client.rpc(
          'update_business_currencies_idempotent',
          params: {
            'p_business_id': payload['p_business_id'],
            'p_additional_currencies': payload['p_additional_currencies'],
            'p_request_id': payload['p_request_id'],
          },
        );
        if (saved is! List) throw StateError('currency_update_unconfirmed');
        return payload['p_business_id'] as String;
      case 'mutate_customer_profile':
        final result = await client.rpc(
          'mutate_customer_profile',
          params: payload,
        );
        if (result is! Map ||
            (result['updated'] != true && result['archived'] != true)) {
          throw StateError('لم يؤكد الخادم تعديل العميل');
        }
        return payload['p_business_customer_id'] as String;
      case 'create_business':
        // Upgrade queued legacy commands to the same receipt contract.
        final profile =
            payload['p_profile'] ??
            {
              'name': payload['p_name'],
              'business_type': payload['p_business_type'],
              'currency_code': payload['p_currency_code'],
              'additional_currencies': payload['p_additional_currencies'] ?? [],
              'country_code': payload['p_country_code'] ?? 'YE',
              'city': payload['p_city'],
              'address': payload['p_address'],
            };
        final result = await client.rpc(
          'create_business_idempotent',
          params: {
            'p_request_id': payload['p_request_id'],
            'p_profile': profile,
          },
        );
        if (result is! String ||
            !RegExp(
              r'^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$',
            ).hasMatch(result)) {
          throw StateError('لم يؤكد الخادم إنشاء النشاط');
        }
        return result as String?;
      case 'upload_business_logo':
        return uploadBusinessLogo(
          client,
          businessId: payload['businessId'] as String,
          requestId: payload['requestId'] as String,
          bytes: base64Decode(payload['bytes'] as String),
          extension: payload['extension'] as String? ?? 'jpg',
        );

      case 'create_ledger_entry':
        // المرفقات تسلك مسار upload_sessions بعد المزامنة (قرار 19) —
        // تُسقط من الحمولة دفاعاً عن الحمولات القديمة أيضاً
        final cleanPayload = Map<String, dynamic>.from(payload)
          ..remove('p_attachment_path');
        final result = await client.rpc(
          'create_ledger_entry',
          params: cleanPayload,
        );
        return result as String?;

      case 'apply_customer_discount':
        final result = await client.rpc(
          'apply_customer_discount',
          params: payload,
        );
        return result as String?;

      case 'reverse_ledger_entry':
        // توحيد اسم المعامل: p_entry_id (توافق مع الحمولات القديمة)
        final cleanPayload = Map<String, dynamic>.from(payload);
        if (cleanPayload.containsKey('p_original_entry_id') &&
            !cleanPayload.containsKey('p_entry_id')) {
          cleanPayload['p_entry_id'] = cleanPayload.remove(
            'p_original_entry_id',
          );
        }
        final result = await client.rpc(
          'reverse_ledger_entry',
          params: cleanPayload,
        );
        return result as String?;

      case 'confirm_ledger_entry':
        await client.rpc('confirm_ledger_entry', params: payload);
        return null;

      case 'open_dispute':
        final result = await client.rpc('open_dispute', params: payload);
        return result as String?;

      case 'resolve_dispute':
        final result = await client.rpc('resolve_dispute', params: payload);
        return result as String?;

      case 'add_dispute_message':
        final result = await client.rpc(
          'add_dispute_message',
          params: {
            'p_dispute_id': payload['p_dispute_id'],
            'p_message': payload['p_message'],
            'p_client_request_id': payload['p_client_request_id'],
            'p_sender_workspace': payload['p_sender_workspace'] ?? 'merchant',
          },
        );
        if (result is! String ||
            !RegExp(
              r'^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$',
            ).hasMatch(result)) {
          throw StateError('لم يؤكد الخادم حفظ رد الاعتراض.');
        }
        return result;

      case 'add_business_customer':
      case 'pending_directory':
      case 'customer_directory':
        // إضافة العميل عبر Edge Function customer-directory (قرار 4):
        // تطبيع E164 + إنشاء customers + تشفير الهاتف + ربط العلاقة ذرّياً
        final response = await client.functions.invoke(
          'customer-directory',
          body: payload,
        );
        final data = response.data;
        if (data is Map &&
            data['businessCustomerId'] is String &&
            (data['businessCustomerId'] as String).isNotEmpty) {
          return data['businessCustomerId'] as String;
        }
        throw StateError(
          'لم يؤكد الخادم إنشاء العميل. سيبقى الطلب محفوظًا للمراجعة.',
        );

      case 'generate_statement':
        final statementId = await client.rpc(
          'create_statement',
          params: {
            'p_scope': 'business_customer',
            'p_business_customer_id': payload['businessCustomerId'],
            'p_period_from': payload['periodFrom'],
            'p_period_to': payload['periodTo'],
            'p_currency_code': payload['currencyCode'],
          },
        );
        final response = await client.functions.invoke(
          'generate-statement',
          body: {'statementId': statementId},
        );
        final data = response.data;
        if (data is Map && data['statementId'] != null) {
          return data['statementId'].toString();
        }
        return statementId?.toString();

      case 'upload_attachment':
        final localPath = payload['localPath']?.toString();
        final entityId = payload['entityId']?.toString();
        final filename = payload['filename']?.toString();
        final mimeType = payload['mimeType']?.toString();
        if (localPath == null ||
            entityId == null ||
            filename == null ||
            mimeType == null) {
          throw StateError('invalid_attachment_payload');
        }
        final file = File(localPath);
        if (!await file.exists()) throw StateError('attachment_file_missing');
        final bytes = await file.readAsBytes();
        final sessionResponse = await client.functions.invoke(
          'signed-document-upload',
          body: {
            'entityType': 'ledger_entry',
            'entityId': entityId,
            'filename': filename,
            'mimeType': mimeType,
            'sizeBytes': bytes.length,
            'sha256Hex': sha256.convert(bytes).toString(),
          },
        );
        final session = sessionResponse.data as Map;
        final signedUrl = session['signedUrl']?.toString();
        final uploadSessionId = session['uploadSessionId']?.toString();
        if (signedUrl == null || uploadSessionId == null) {
          throw StateError('signed_upload_session_missing');
        }
        final upload = await http.put(
          Uri.parse(signedUrl),
          headers: {'content-type': mimeType},
          body: bytes,
        );
        if (upload.statusCode < 200 || upload.statusCode >= 300) {
          throw HttpException('attachment_upload_${upload.statusCode}');
        }
        final finalized = await client.functions.invoke(
          'finalize-document-upload',
          body: {'uploadSessionId': uploadSessionId},
        );
        final result = finalized.data;
        return result is Map ? result['fileId']?.toString() : null;

      case 'update_business_profile':
        final businessId = payload['businessId']?.toString();
        if (businessId == null || businessId.isEmpty) {
          throw StateError('missing_business_id');
        }
        // Old device queues include updated_at, which is server-owned and
        // deliberately has no authenticated column UPDATE grant.
        const editable = {
          'name',
          'business_type',
          'country_code',
          'city',
          'address',
          'contact_phone_display',
          'timezone',
        };
        final values = <String, dynamic>{
          for (final key in editable)
            if (payload.containsKey(key)) key: payload[key],
        };
        if (values.isEmpty) throw StateError('empty_business_profile');
        final updated = await client
            .from('businesses')
            .update(values)
            .eq('id', businessId)
            .select('id')
            .maybeSingle();
        if (updated?['id'] != businessId) {
          throw const PostgrestException(
            message: 'Business update not authorized or unavailable',
            code: '42501',
          );
        }
        return businessId;

      default:
        throw StateError('unknown_command:$commandType');
    }
  }

  /// بعد نجاح الإرسال: تسوية المعرّفات المحلية + حذف الأمر من الطابور.
  Future<void> _reconcileSuccess(
    Map<String, dynamic> mutation,
    String? serverEntityId,
  ) async {
    final db = AppDatabase.instance;
    final String clientRequestId = mutation['client_request_id'];
    final String commandType = mutation['command_type'];
    final String? localRefId = mutation['local_ref_id'] as String?;
    if (commandType == 'mutate_customer_profile' && localRefId != null) {
      await db.completeCustomerProfileMutation(clientRequestId, localRefId);
      return;
    }

    if (commandType == 'create_business') {
      if (serverEntityId != null && localRefId != null) {
        await db.reconcileBusinessId(
          localId: localRefId,
          serverId: serverEntityId,
        );
      }
    } else if (commandType == 'add_business_customer' ||
        commandType == 'pending_directory' ||
        commandType == 'customer_directory') {
      if (serverEntityId != null && localRefId != null) {
        await db.reconcileCustomerId(
          localId: localRefId,
          serverId: serverEntityId,
        );
      }
    } else if (commandType == 'create_ledger_entry' ||
        commandType == 'apply_customer_discount' ||
        commandType == 'reverse_ledger_entry') {
      if (serverEntityId != null && localRefId != null) {
        await db.reconcileEntryId(
          localId: localRefId,
          serverId: serverEntityId,
        );
      } else {
        await db.markLedgerEntrySynced(clientRequestId);
      }
    } else if (commandType == 'upload_business_logo' &&
        serverEntityId != null &&
        localRefId != null) {
      final local = await db.database;
      await local.update(
        'local_businesses',
        {'logo_path': serverEntityId},
        where: 'id=?',
        whereArgs: [localRefId],
      );
    } else if (commandType == 'add_dispute_message' && serverEntityId != null) {
      await db.reconcileDisputeMessage(clientRequestId, serverEntityId);
    }

    // نجحت العملية -> إزالة من الطابور (الأوامر المعتمدة تتحرر تلقائياً)
    await db.removeMutation(clientRequestId);
  }

  // ==================== Pull: سحب البيانات من السحابة ====================

  Future<void> _pullRemoteUpdates(String syncAccountId) async {
    final client = _client;
    requireCloudSession(client, syncAccountId);
    final user = client.auth.currentUser;
    if (user == null) throw StateError('انتهت الجلسة أثناء جلب البيانات.');

    try {
      try {
        final currencyRows = await collectAllPages<Map<String, dynamic>>(
          fetchPage: (from, to) async => await client
              .from('currencies')
              .select('code,name,symbol,decimal_scale,is_active,updated_at')
              .eq('is_active', true)
              .order('code')
              .range(from, to)
              .timeout(const Duration(seconds: 15)),
        );
        await AppDatabase.instance.upsertCurrencies(
          currencyRows.map((row) => Map<String, dynamic>.from(row)).toList(),
        );
      } catch (e) {
        debugPrint('[SyncEngine] Currency catalog pull failed: $e');
        rethrow;
      }

      // 1. سحب بيانات المحلات التي ينتمي إليها المستخدم
      if (_paused) return;
      final memberBusinesses = await collectAllPages<Map<String, dynamic>>(
        fetchPage: (from, to) async => await client
            .from('business_members')
            .select('businesses(*)')
            .eq('user_id', user.id)
            .eq('status', 'active')
            .order('business_id')
            .range(from, to)
            .timeout(const Duration(seconds: 15)),
      );

      for (final row in memberBusinesses) {
        if (_paused) return;
        requireCloudSession(_client, syncAccountId);
        assertSyncAccount(
          expected: syncAccountId,
          current: AppDatabase.instance.accountId,
        );
        final b = row['businesses'] as Map<String, dynamic>?;
        if (b == null) throw StateError('تعذر جلب بيانات نشاط مرتبط بالحساب.');

        final businessId = b['id'] as String;
        await AppDatabase.instance.saveBusiness({
          'id': businessId,
          'owner_user_id': b['owner_user_id'],
          'name': b['name'],
          'business_type': b['business_type'],
          'currency_code': b['currency_code'] ?? 'YER',
          'additional_currencies': jsonEncode(
            (b['additional_currencies'] as List?)
                    ?.map((e) => e.toString().toUpperCase())
                    .toList() ??
                const [],
          ),
          'country_code': b['country_code'] ?? 'YE',
          'city': b['city'],
          'contact_phone': b['contact_phone_display'],
          'logo_path': b['logo_path'],
          'is_active': 1,
          'created_at': b['created_at'],
        });

        // Apply one financial snapshot atomically, then hydrate private contacts and disputes.
        await _pullMerchantSnapshot(client, businessId, syncAccountId);
        if (_paused) return;
        await _pullDisputes(client, businessId);
        if (_paused) return;
        await _pullCustomerContacts(client, businessId, syncAccountId);
      }
    } catch (e) {
      debugPrint('[SyncEngine] Pull update error: $e');
      rethrow;
    }
  }

  /// سحب العملاء + أرصدتهم المسطحة باستعلام مجمّع واحد (إصلاح N+1)،
  /// مع حماية السجلات pending من الكتابة الفوقية.
  Future<void> _pullMerchantSnapshot(
    SupabaseClient client,
    String businessId,
    String accountId,
  ) async {
    final db = AppDatabase.instance;
    final local = await db.database;
    final pending = await local.query(
      'local_ledger_entries',
      columns: ['client_request_id'],
      where: "business_id=? AND sync_status != 'synced'",
      whereArgs: [businessId],
    );
    final requestIds = pending
        .map((r) => r['client_request_id'] as String)
        .where((id) => RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id))
        .toList();
    final result = await client
        .rpc(
          'begin_merchant_sync_snapshot',
          params: {
            'p_business_id': businessId,
            'p_cursor': await db.getLocalCheckpoint(businessId),
            'p_pending_requests': requestIds,
            'p_device_id': await _getOrCreateDeviceId(db),
            'p_previous_snapshot_id': await db.getSyncStateValue(
              'snapshot:$businessId',
            ),
          },
        )
        .timeout(const Duration(seconds: 15));
    if (result is! Map ||
        result['snapshot_id'] is! String ||
        result['item_count'] is! num) {
      throw StateError('Invalid snapshot');
    }
    final count = (result['item_count'] as num).toInt();
    final items = <Map<String, dynamic>>[];
    var after = 0;
    while (items.length < count) {
      if (_paused) return;
      final page = await client
          .rpc(
            'read_merchant_sync_snapshot',
            params: {
              'p_snapshot_id': result['snapshot_id'],
              'p_after': after,
              'p_limit': 500,
            },
          )
          .timeout(const Duration(seconds: 15));
      if (page is! List || page.isEmpty) {
        throw StateError('Incomplete snapshot');
      }
      for (final raw in page) {
        final row = Map<String, dynamic>.from(raw as Map);
        final ordinal = (row['ordinal'] as num).toInt();
        if (ordinal != after + 1 ||
            !['entry', 'state', 'customer', 'balance'].contains(row['kind']) ||
            row['payload'] is! Map) {
          throw StateError('Invalid snapshot page');
        }
        after = ordinal;
        items.add(row);
      }
    }
    if (items.length != count) throw StateError('Invalid snapshot size');
    if (_paused) return;
    requireCloudSession(client, accountId);
    assertSyncAccount(expected: accountId, current: db.accountId);
    await db.applyMerchantSnapshot(
      businessId,
      items,
      snapshotId: result['snapshot_id'] as String,
    );
    await _notify(
      SyncState.syncing,
      'تم تحديث بيانات الدفتر',
      dataChanged: true,
    );
    unawaited(() async {
      try {
        await client
            .rpc(
              'release_merchant_sync_snapshot',
              params: {'p_snapshot_id': result['snapshot_id']},
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // An expired/disposable server copy never invalidates an applied snapshot.
      }
    }());
  }

  Future<void> _pullDisputes(SupabaseClient client, String businessId) async {
    final owner = AppDatabase.instance.accountId;
    if (owner == null) return;
    try {
      final rows = await collectAllPages<Map<String, dynamic>>(
        fetchPage: (from, to) async => await client
            .from('disputes')
            .select(
              'id, entry_id, business_id, customer_id, reason, description, '
              'created_at, dispute_state(status, resolution_note)',
            )
            .eq('business_id', businessId)
            .order('id')
            .range(from, to)
            .timeout(const Duration(seconds: 15)),
      );

      for (final row in rows) {
        if (_paused) return;
        assertSyncAccount(
          expected: owner,
          current: AppDatabase.instance.accountId,
        );
        final state = row['dispute_state'];
        String status = 'open';
        String? resolutionNote;
        if (state is Map) {
          status = (state['status'] as String?) ?? 'open';
          resolutionNote = state['resolution_note'] as String?;
        } else if (state is List && state.isNotEmpty) {
          status = (state.first['status'] as String?) ?? 'open';
          resolutionNote = state.first['resolution_note'] as String?;
        }

        await AppDatabase.instance.upsertLocalDispute({
          'id': row['id'],
          'entry_id': row['entry_id'],
          'business_id': row['business_id'],
          'customer_id': row['customer_id'],
          'reason': row['reason'] ?? '',
          'description': row['description'] ?? '',
          'status': status,
          'resolution_note': resolutionNote,
          'created_at': row['created_at'],
        });
      }
      // Publish every dispute before requesting any conversation. A failed
      // message page must not hide subsequent disputes from this merchant.
      await _notify(
        SyncState.syncing,
        'تم تحديث قائمة الاعتراضات',
        dataChanged: true,
      );
      Object? messageError;
      StackTrace? messageStack;
      for (final row in rows) {
        if (_paused) return;
        try {
          final messages = await collectAllPages<Map<String, dynamic>>(
            fetchPage: (from, to) async => await client
                .from('dispute_messages')
                .select(
                  'id,dispute_id,sender_user_id,sender_workspace,message,created_at',
                )
                .eq('dispute_id', row['id'])
                .order('id')
                .range(from, to)
                .timeout(const Duration(seconds: 15)),
          );
          assertSyncAccount(
            expected: owner,
            current: AppDatabase.instance.accountId,
          );
          for (final message in messages) {
            await AppDatabase.instance.saveDisputeMessage({
              ...message,
              'sync_status': 'synced',
              'client_request_id': null,
            });
          }
        } catch (error, stack) {
          assertSyncAccount(
            expected: owner,
            current: AppDatabase.instance.accountId,
          );
          messageError ??= error;
          messageStack ??= stack;
        }
      }
      if (messageError != null) {
        Error.throwWithStackTrace(messageError, messageStack!);
      }
    } catch (e) {
      debugPrint('[SyncEngine] Disputes pull failed: $e');
      rethrow;
    }
  }

  // ==================== نقاط التحقق (sync_checkpoints) ====================

  /// معرّف جهاز ثابت (UUID) يُولَّد مرة واحدة ويُخزَّن محلياً.
  Future<String> _getOrCreateDeviceId(AppDatabase db) async {
    final existingId = await db.getSyncStateValue('device_id');
    if (existingId != null && existingId.isNotEmpty) {
      return existingId;
    }
    final newId = _uuid.v4();
    await db.setSyncStateValue('device_id', newId);
    return newId;
  }

  Future<void> _pullCustomerContacts(
    SupabaseClient client,
    String businessId,
    String accountId,
  ) async {
    final db = AppDatabase.instance;
    final rows = await db.getContactsNeedingRefresh(businessId);
    if (rows.isEmpty) return;
    final deviceId = await _getOrCreateDeviceId(db);
    await client.rpc(
      'register_customer_contact_device',
      params: {
        'p_device_id': deviceId,
        'p_platform': kIsWeb
            ? 'web'
            : defaultTargetPlatform == TargetPlatform.iOS
            ? 'ios'
            : 'android',
      },
    );
    for (var offset = 0; offset < rows.length; offset += 100) {
      if (_paused) return;
      final batch = rows.sublist(offset, min(offset + 100, rows.length));
      final response = await client.functions.invoke(
        'customer-contacts',
        body: {
          'deviceId': deviceId,
          'businessId': businessId,
          'customerIds': batch.map((r) => r['id']).toList(),
        },
      );
      requireCloudSession(client, accountId);
      assertSyncAccount(expected: accountId, current: db.accountId);
      final data = response.data;
      if (data is! Map || data['contacts'] is! List) {
        throw StateError('Invalid contact response');
      }
      final requestedIds = batch.map((r) => r['id']).toSet();
      final phones = <String, String>{};
      for (final item in data['contacts'] as List) {
        if (item is! Map ||
            !requestedIds.contains(item['businessCustomerId']) ||
            item['phone'] is! String) {
          throw StateError('Invalid contact response');
        }
        phones[item['businessCustomerId'] as String] = item['phone'] as String;
      }
      await db.cacheCustomerContacts(businessId, batch, phones);
    }
  }
}
