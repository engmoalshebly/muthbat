import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';

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

  const SyncProgress({
    this.state = SyncState.idle,
    this.pendingCount = 0,
    this.failedCount = 0,
    this.deadLetterCount = 0,
    this.lastMessage,
    this.lastSyncAt,
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
class SyncEngine {
  SyncEngine._();
  static final SyncEngine instance = SyncEngine._();

  static const _uuid = Uuid();
  static final _random = Random();

  final _progressController = StreamController<SyncProgress>.broadcast();
  Stream<SyncProgress> get progressStream => _progressController.stream;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _periodicTimer;
  bool _isProcessing = false;
  DateTime? _lastSyncAt;

  /// بدء الاستماع لشبكة الإنترنت والمزامنة الدورية
  void init() {
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
    _connectivitySub?.cancel();
    _periodicTimer?.cancel();
    _progressController.close();
  }

  void _notify(SyncState state, [String? message]) async {
    final counts = await AppDatabase.instance.getMutationStatusCounts();
    _progressController.add(
      SyncProgress(
        state: state,
        pendingCount:
            (counts['pending'] ?? 0) +
            (counts['syncing'] ?? 0) +
            (counts['failed'] ?? 0),
        failedCount: counts['failed'] ?? 0,
        deadLetterCount: counts['dead_letter'] ?? 0,
        lastMessage: message,
        lastSyncAt: _lastSyncAt,
      ),
    );
  }

  /// تشغيل المزامنة اليدوية أو التلقائية
  Future<void> triggerSync() async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final connectivity = await Connectivity().checkConnectivity();
      final isOnline = connectivity.any((r) => r != ConnectivityResult.none);
      if (!isOnline) {
        _notify(SyncState.offline, 'لا يوجد اتصال بالإنترنت (العمل محلياً)');
        return;
      }

      final pendingCount = await AppDatabase.instance
          .getPendingMutationsCount();
      if (pendingCount > 0) {
        _notify(SyncState.syncing, 'جاري مزامنة $pendingCount عملية معلقة...');
      }

      // 1. معالجة العمليات غير المرسلة في الطابور (Push Queue)
      await _processPendingMutations();

      // 2. سحب البيانات المحدثة من السحابة (Pull Updates)
      await _pullRemoteUpdates();

      _lastSyncAt = DateTime.now();

      final remaining = await AppDatabase.instance.getPendingMutationsCount();
      final deadLetter = await AppDatabase.instance.getDeadLetterCount();
      if (remaining == 0 && deadLetter == 0) {
        _notify(SyncState.synced, 'تمت المزامنة بنجاح وكل البيانات موثقة');
      } else if (deadLetter > 0) {
        _notify(SyncState.error, '$deadLetter عملية تحتاج مراجعة');
      } else {
        _notify(SyncState.idle, '$remaining عمليات متبقية');
      }
    } catch (e) {
      debugPrint('[SyncEngine] Sync error: $e');
      _notify(SyncState.error, 'تعذرت المزامنة: $e');
    } finally {
      _isProcessing = false;
    }
  }

  // ==================== Push: إرسال الأوامر المعلقة ====================

  Future<void> _processPendingMutations() async {
    final client = Supabase.instance.client;
    if (client.auth.currentSession == null) return;

    final db = AppDatabase.instance;

    // استرجاع العناصر العالقة في syncing بعد إغلاق مفاجئ سابق
    await db.recoverStuckSyncingMutations();

    final mutations = await db.getDueMutations(DateTime.now());

    for (final mutation in mutations) {
      final String clientRequestId = mutation['client_request_id'];
      final String commandType = mutation['command_type'];
      final int attemptCount =
          (mutation['attempt_count'] as num?)?.toInt() ?? 0;
      final Map<String, dynamic> payload =
          jsonDecode(mutation['payload_json']) as Map<String, dynamic>;

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
        final serverEntityId = await _dispatchCommand(
          client,
          commandType,
          payload,
        );
        await _reconcileSuccess(mutation, serverEntityId);
      } catch (error) {
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
          (value.startsWith('cust-') || value.startsWith('entry-'))) {
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
      case 'create_business':
        final result = await client.rpc('create_business', params: payload);
        return result as String?;

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
        if (data is Map && data['businessCustomerId'] != null) {
          return data['businessCustomerId'] as String;
        }
        return null;

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

      case 'update_business_profile':
        final businessId = payload['businessId']?.toString();
        if (businessId == null || businessId.isEmpty) {
          throw StateError('missing_business_id');
        }
        final values = Map<String, dynamic>.from(payload)..remove('businessId');
        await client.from('businesses').update(values).eq('id', businessId);
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

    if (commandType == 'create_business') {
      if (serverEntityId != null && localRefId != null) {
        final dbInstance = await db.database;
        await dbInstance.rawUpdate(
          'UPDATE local_businesses SET id = ? WHERE id = ?',
          [serverEntityId, localRefId],
        );
        await dbInstance.rawUpdate(
          'UPDATE local_business_customers SET business_id = ? WHERE business_id = ?',
          [serverEntityId, localRefId],
        );
        await dbInstance.rawUpdate(
          'UPDATE local_ledger_entries SET business_id = ? WHERE business_id = ?',
          [serverEntityId, localRefId],
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
    }

    // نجحت العملية -> إزالة من الطابور (الأوامر المعتمدة تتحرر تلقائياً)
    await db.removeMutation(clientRequestId);
  }

  // ==================== Pull: سحب البيانات من السحابة ====================

  Future<void> _pullRemoteUpdates() async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) return;

    try {
      try {
        final currencyRows = await client
            .from('currencies')
            .select('code,name,symbol,decimal_scale,is_active,updated_at')
            .eq('is_active', true)
            .order('code');
        await AppDatabase.instance.upsertCurrencies(
          currencyRows.map((row) => Map<String, dynamic>.from(row)).toList(),
        );
      } catch (e) {
        debugPrint('[SyncEngine] Currency catalog pull skipped: $e');
      }

      // 1. سحب بيانات المحلات التي ينتمي إليها المستخدم
      final memberBusinesses = await client
          .from('business_members')
          .select('businesses(*)')
          .eq('user_id', user.id)
          .eq('status', 'active');

      for (final row in memberBusinesses) {
        final b = row['businesses'] as Map<String, dynamic>?;
        if (b == null) continue;

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
          'is_active': 1,
          'created_at': b['created_at'],
        });

        // الترتيب: عملاء → قيود (تزايدي) → أرصدة عملات → نزاعات
        await _pullCustomers(client, businessId);
        await _pullLedgerEntries(client, user.id, businessId);
        await _pullCurrencyBalances(client, businessId);
        await _pullDisputes(client, businessId);
      }
    } catch (e) {
      debugPrint('[SyncEngine] Pull update error: $e');
    }
  }

  /// سحب العملاء + أرصدتهم المسطحة باستعلام مجمّع واحد (إصلاح N+1)،
  /// مع حماية السجلات pending من الكتابة الفوقية.
  Future<void> _pullCustomers(SupabaseClient client, String businessId) async {
    final customers = await client
        .from('business_customers')
        .select('*, customers(global_code)')
        .eq('business_id', businessId)
        .eq('is_archived', false);

    // استعلام مجمّع واحد للأرصدة بدل استعلام لكل عميل
    final businessRow = await client
        .from('businesses')
        .select('currency_code')
        .eq('id', businessId)
        .single();
    final baseCurrency = (businessRow['currency_code'] as String? ?? 'YER')
        .toUpperCase();
    final balanceRows = await client
        .from('business_customer_balances')
        .select(
          'business_customer_id, currency_code, current_balance, gross_overdue_debits',
        )
        .eq('business_id', businessId);

    final Map<String, double> balances = {};
    final Map<String, double> overdueByCustomer = {};
    for (final row in balanceRows) {
      if ((row['currency_code'] as String? ?? baseCurrency).toUpperCase() ==
          baseCurrency) {
        final customerId = row['business_customer_id'] as String;
        balances[customerId] =
            (row['current_balance'] as num?)?.toDouble() ?? 0.0;
        overdueByCustomer[customerId] =
            (row['gross_overdue_debits'] as num?)?.toDouble() ?? 0.0;
      }
    }

    for (final c in customers) {
      final double currentBal = balances[c['id'] as String] ?? 0.0;
      final double owes = currentBal > 0 ? currentBal : 0.0;
      final double advance = currentBal < 0 ? currentBal.abs() : 0.0;

      await AppDatabase.instance.upsertBusinessCustomer({
        'id': c['id'],
        'business_id': businessId,
        'customer_id': c['customer_id'],
        'local_display_name': c['local_display_name'],
        'local_note': c['local_note'],
        'credit_limit': (c['credit_limit'] as num?)?.toDouble(),
        'default_due_days': c['default_due_days'],
        'link_status': c['link_status'] ?? 'unlinked',
        'current_balance': currentBal,
        'amount_customer_owes': owes,
        'amount_business_owes_customer': advance,
        'overdue_balance': overdueByCustomer[c['id'] as String] ?? 0.0,
        'is_archived': 0,
        'sync_status': 'synced',
        'created_at': c['created_at'],
        'updated_at': c['updated_at'],
      }, fromServer: true);
    }
  }

  /// سحب القيود المالية تزايدياً عبر sync_checkpoints (لكل مستخدم/جهاز/محل):
  /// يجلب فقط ما هو أحدث من المؤشر، ويحدّث المؤشر بعد نجاح الدفعة.
  Future<void> _pullLedgerEntries(
    SupabaseClient client,
    String userId,
    String businessId,
  ) async {
    final db = AppDatabase.instance;
    final deviceId = await _getOrCreateDeviceId(db);

    // المؤشر الفعّال: المحلي أولاً ثم مؤشر السيرفر كاحتياط
    String? cursor = await db.getLocalCheckpoint(businessId);
    cursor ??= await _getServerCheckpoint(client, deviceId, businessId);

    var filter = client
        .from('ledger_timeline')
        .select(
          'id, business_id, business_customer_id, customer_id, entry_type, '
          'direction, amount, currency_code, description, occurred_at, '
          'category, payment_method, reference_number, bank_or_agent_name, attachment_url, '
          'due_date, external_reference, client_request_id, created_at, '
          'confirmation_status, dispute_status, is_reversed',
        )
        .eq('business_id', businessId);

    if (cursor != null && cursor.isNotEmpty) {
      filter = filter.gt('created_at', cursor);
    }

    final rows = await filter.order('created_at', ascending: true).limit(500);
    if (rows.isEmpty) return;

    for (final row in rows) {
      await db.upsertLedgerEntryFromServer(Map<String, dynamic>.from(row));
    }

    // تحديث المؤشر بعد نجاح الدفعة (محلياً + السيرفر بأفضل جهد)
    final newCursor = rows.last['created_at'] as String?;
    if (newCursor != null) {
      await db.setLocalCheckpoint(businessId, newCursor);
      await _setServerCheckpoint(
        client,
        userId,
        deviceId,
        businessId,
        newCursor,
      );
    }
  }

  /// سحب أرصدة العملات من السيرفر باستعلام مجمّع واحد لكل محل.
  Future<void> _pullCurrencyBalances(
    SupabaseClient client,
    String businessId,
  ) async {
    try {
      final rows = await client
          .from('customer_currency_balances')
          .select(
            'business_customer_id, currency_code, current_balance, '
            'total_debits, total_credits, entry_count, last_entry_at',
          )
          .eq('business_id', businessId);

      await AppDatabase.instance.upsertCurrencyBalancesFromServer(
        businessId,
        rows.map((r) => Map<String, dynamic>.from(r)).toList(),
      );
    } catch (e) {
      // الجدول قد لا يكون منشوراً بعد في بيئة لم يصلها ترحيل العملات —
      // لا نكسر جولة السحب بسببه
      debugPrint('[SyncEngine] Currency balances pull skipped: $e');
    }
  }

  /// سحب النزاعات دورياً (Server-wins — دورة حياتها تُدار في الباكند).
  Future<void> _pullDisputes(SupabaseClient client, String businessId) async {
    try {
      final rows = await client
          .from('disputes')
          .select(
            'id, entry_id, business_id, customer_id, reason, description, '
            'created_at, dispute_state(status, resolution_note)',
          )
          .eq('business_id', businessId);

      for (final row in rows) {
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
    } catch (e) {
      debugPrint('[SyncEngine] Disputes pull skipped: $e');
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

  Future<String?> _getServerCheckpoint(
    SupabaseClient client,
    String deviceId,
    String businessId,
  ) async {
    try {
      final row = await client
          .from('sync_checkpoints')
          .select('cursor_value')
          .eq('device_id', deviceId)
          .eq('business_id', businessId)
          .maybeSingle();
      return row?['cursor_value'] as String?;
    } catch (e) {
      debugPrint('[SyncEngine] Server checkpoint read skipped: $e');
      return null;
    }
  }

  Future<void> _setServerCheckpoint(
    SupabaseClient client,
    String userId,
    String deviceId,
    String businessId,
    String cursorValue,
  ) async {
    try {
      final existing = await client
          .from('sync_checkpoints')
          .select('id')
          .eq('device_id', deviceId)
          .eq('business_id', businessId)
          .maybeSingle();

      if (existing != null) {
        await client
            .from('sync_checkpoints')
            .update({'cursor_value': cursorValue})
            .eq('id', existing['id']);
      } else {
        await client.from('sync_checkpoints').insert({
          'user_id': userId,
          'device_id': deviceId,
          'business_id': businessId,
          'cursor_value': cursorValue,
        });
      }
    } catch (e) {
      // المؤشر المحلي هو المرجع الملزم — فشل مرآة السيرفر لا يكسر المزامنة
      debugPrint('[SyncEngine] Server checkpoint write skipped: $e');
    }
  }
}
