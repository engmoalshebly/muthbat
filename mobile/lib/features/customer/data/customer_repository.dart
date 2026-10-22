import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'models/customer_summary_model.dart';
import 'customer_outbox.dart';
import 'customer_local_store.dart';
import '../../../core/database/app_database.dart';
import '../../../core/config/env.dart';
import '../../../core/security/cloud_session.dart';
import '../../../core/sync/user_contact_bootstrap.dart';

/// طبقة بيانات شاشة العميل — قراءة مباشرة من عروض Supabase العامة المحمية بـ RLS
/// (`customer_business_summary`, `customer_link_requests`, `ledger_timeline`)
/// وأوامر العميل العامة (`respond_link_request`, `confirm_ledger_entry`).
///
/// ممنوع الابتلاع الصامت للأخطاء: كل فشل يُرمى برسالة عربية واضحة تعرضها الواجهة.
class CustomerPhoneVerificationRequired implements Exception {
  const CustomerPhoneVerificationRequired();
  @override
  String toString() =>
      'وثّق ملكية رقمك عبر استعادة الحساب برمز التحقق لإظهار حساباتك لدى البقالات.';
}

class CustomerReadSnapshot {
  const CustomerReadSnapshot({
    required this.customerId,
    required this.updatedAt,
    required this.summaries,
    required this.requests,
    required this.entries,
  });
  final String? customerId;
  final String updatedAt;
  final List<CustomerBusinessSummary> summaries;
  final List<CustomerLinkRequestModel> requests;
  final List<Map<String, dynamic>> entries;
}

class CustomerRepository {
  CustomerRepository({SupabaseClient? client}) : _injectedClient = client;
  final SupabaseClient? _injectedClient;
  final _outbox = CustomerOutbox();
  bool _flushing = false;
  final local = CustomerLocalStore();

  /// Sync all relationships sequentially; navigation never waits for this.
  Future<void> syncLocalLedgers(CustomerReadSnapshot home) async {
    final owner = userId;
    if (owner == null) return;
    await local.saveHome(owner, home);
    for (final summary in home.summaries) {
      if (userId != owner) return;
      // Each completed ledger is atomic. Refresh on every new home generation,
      // including confirmations/dispute changes that don't change entry counts.
      final snapshot = await fetchCompleteLedger(
        businessCustomerId: summary.businessCustomerId,
        currency: summary.currencyCode,
      );
      if (userId != owner) return;
      await local.saveLedger(
        owner,
        snapshot,
        relationship: summary.businessCustomerId,
        currency: summary.currencyCode,
      );
    }
  }

  Future<List<Map<String, dynamic>>> pendingActions() async =>
      userId == null ? [] : _outbox.list(userId!);

  Future<void> retryAction(String id) async {
    if (userId != null) await _outbox.retry(userId!, id);
  }

  Future<void> replyToDispute(String id, String message) async {
    final text = message.trim();
    if (text.isEmpty || text.length > 4000) {
      throw ArgumentError('اكتب رسالة بين 1 و4000 حرف');
    }
    await _enqueue({'kind': 'dispute_reply', 'target_id': id, 'message': text});
  }

  Future<void> flushOutbox() async {
    if (_flushing) return;
    final owner = userId;
    if (owner == null) return;
    try {
      _requireOnlineSession();
    } catch (_) {
      return;
    }
    _flushing = true;
    try {
      final pending = await _outbox.list(owner);
      final elapsed = Stopwatch()..start();
      for (final action
          in pending.where((e) => e['status'] == 'pending').take(50)) {
        if (elapsed.elapsed >= const Duration(seconds: 20)) return;
        if (userId != owner) return;
        try {
          final result = await _client
              .rpc(
                'submit_customer_action',
                params: {
                  'p_request_id': action['id'],
                  'p_payload': jsonDecode(action['payload'] as String),
                },
              )
              .timeout(const Duration(seconds: 8));
          if (userId != owner) return;
          if (result is! Map || result['completed'] != true) {
            throw StateError('لم يؤكد الخادم اكتمال الطلب');
          }
          await _outbox.complete(owner, action['id'] as String);
        } on PostgrestException catch (e) {
          // Missing deployment, rate limits and auth errors remain retryable.
          if (userId != owner) return;
          if ([
            'P0001',
            '22023',
            '22P02',
            '23505',
            '42501',
            '55000',
          ].contains(e.code)) {
            await _outbox.fail(owner, action['id'] as String, friendlyError(e));
            continue;
          }
          return;
        } catch (_) {
          return;
        } // Keep the same request id after uncertain delivery.
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> _enqueue(Map<String, dynamic> payload) async {
    final owner = userId;
    if (owner == null) throw StateError('افتح حسابك أولًا');
    await _outbox.enqueue(owner, payload);
  }

  String? get userId => AppDatabase.instance.accountId;

  Future<CustomerReadSnapshot> fetchHomeSnapshot() => _fetchSnapshot('home');
  Future<CustomerReadSnapshot> fetchCompleteLedger({
    required String businessCustomerId,
    required String currency,
  }) => _fetchSnapshot(
    'ledger',
    businessCustomerId: businessCustomerId,
    currency: currency,
  );

  Future<CustomerReadSnapshot> _fetchSnapshot(
    String scope, {
    String? businessCustomerId,
    String? currency,
  }) async {
    _requireOnlineSession();
    final owner = userId;
    final elapsed = Stopwatch()..start();
    String? snapshotId;
    void checkAccount() {
      if (owner != userId) throw StateError('تغير الحساب أثناء تحميل البيانات');
      _requireOnlineSession();
    }

    try {
      final result = await _client
          .rpc(
            'begin_customer_read_snapshot',
            params: {
              'p_scope': scope,
              'p_business_customer_id': businessCustomerId,
              'p_currency_code': currency,
            },
          )
          .timeout(const Duration(seconds: 30));
      checkAccount();
      if (result is! Map ||
          result['snapshot_id'] is! String ||
          result['item_count'] is! num) {
        throw StateError('استجابة لقطة الحساب غير مكتملة');
      }
      snapshotId = result['snapshot_id'] as String;
      final count = (result['item_count'] as num).toInt();
      final items = <Map<String, dynamic>>[];
      var after = 0;
      while (items.length < count) {
        final response = await _client
            .rpc(
              'read_customer_read_snapshot',
              params: {
                'p_snapshot_id': snapshotId,
                'p_after': after,
                'p_limit': 250,
              },
            )
            .timeout(const Duration(seconds: 30));
        checkAccount();
        final page = List<Map<String, dynamic>>.from(response as List);
        if (page.isEmpty) {
          throw StateError('لم يكتمل تحميل الحساب. أعد المحاولة');
        }
        for (final item in page) {
          final ordinal = (item['ordinal'] as num).toInt();
          if (ordinal != after + 1) {
            throw StateError('ترتيب صفحات الحساب غير مكتمل');
          }
          after = ordinal;
          items.add(item);
        }
        if (items.length > count) {
          throw StateError('عدد عناصر الحساب غير متطابق');
        }
      }
      final metadata = Map<String, dynamic>.from(
        items.singleWhere((e) => e['kind'] == 'metadata')['payload'] as Map,
      );
      final summaries = items
          .where((e) => e['kind'] == 'summary')
          .map(
            (e) => CustomerBusinessSummary.fromMap(
              Map<String, dynamic>.from(e['payload'] as Map),
            ),
          )
          .toList();
      final entries = items
          .where((e) => e['kind'] == 'entry')
          .map((e) => Map<String, dynamic>.from(e['payload'] as Map))
          .toList();
      entries.sort((a, b) {
        final order = DateTime.parse(
          b['occurred_at'] as String,
        ).compareTo(DateTime.parse(a['occurred_at'] as String));
        return order != 0
            ? order
            : (b['id'] as String).compareTo(a['id'] as String);
      });
      final snapshot = CustomerReadSnapshot(
        customerId: metadata['customer_id'] as String?,
        updatedAt: metadata['updated_at'] as String,
        summaries: summaries,
        requests: items
            .where((e) => e['kind'] == 'request')
            .map(
              (e) => CustomerLinkRequestModel.fromMap(
                Map<String, dynamic>.from(e['payload'] as Map),
              ),
            )
            .toList(),
        entries: entries,
      );
      debugPrint(
        '[CustomerRead] $scope completed: ${items.length} items in '
        '${elapsed.elapsedMilliseconds}ms',
      );
      return snapshot;
    } catch (error) {
      debugPrint(
        '[CustomerRead] $scope deferred after ${elapsed.elapsedMilliseconds}ms: '
        '${error.runtimeType}',
      );
      rethrow;
    } finally {
      if (snapshotId != null && owner == userId) {
        // Cleanup is disposable and must not delay a completed financial read.
        unawaited(() async {
          try {
            await _client
                .rpc(
                  'release_customer_read_snapshot',
                  params: {'p_snapshot_id': snapshotId},
                )
                .timeout(const Duration(seconds: 5));
          } catch (_) {
            /* Expiry job removes abandoned snapshots. */
          }
        }());
      }
    }
  }

  void _requireOnlineSession() {
    final session = _client.auth.currentSession;
    if (!canUseCloudSession(session, userId)) {
      throw StateError(
        'بياناتك المحفوظة متاحة. اتصل بالإنترنت وسجّل الدخول لاستكمال التحديث أو إرسال العمليات.',
      );
    }
  }

  Future<void> refreshPhoneLinks() async {
    _requireOnlineSession();
    final user = _client.auth.currentUser;
    if ((user?.appMetadata['phone_verification_bypassed'] == true &&
            !EnvConfig.allowStagingUnverifiedPhoneLinks) ||
        user?.phoneConfirmedAt == null) {
      throw const CustomerPhoneVerificationRequired();
    }
    try {
      final response = await bootstrapUserContact(_client);
      if (response.data is! Map || response.data['customerId'] is! String) {
        throw StateError(
          'لم يؤكد الخادم ربط رقم الهاتف. ستتم إعادة المحاولة تلقائيًا.',
        );
      }
    } on FunctionException catch (e) {
      if (e.status == 403 || e.status == 422) {
        throw const CustomerPhoneVerificationRequired();
      }
      if (e.status == 409) {
        throw Exception(
          'يوجد تعارض في ملكية الرقم أو سجل سابق. تواصل مع الدعم؛ لم تُدمج الحسابات تلقائيًا.',
        );
      }
      throw Exception(friendlyError(e));
    }
  }

  Future<List<Map<String, dynamic>>> fetchLedgerPage({
    required String businessCustomerId,
    required String currency,
    required int offset,
  }) async {
    _requireOnlineSession();
    if (offset < 0) throw ArgumentError.value(offset);
    final result = await _client
        .from('ledger_timeline')
        .select(
          'id,business_customer_id,entry_type,direction,amount,currency_code,description,occurred_at,confirmation_status,dispute_status,is_reversed,dispute_resolution_note,dispute_resolved_at',
        )
        .eq('business_customer_id', businessCustomerId)
        .eq('currency_code', currency)
        .order('occurred_at', ascending: false)
        .order('id', ascending: false)
        .range(offset, offset + 49)
        .timeout(const Duration(seconds: 15));
    return List<Map<String, dynamic>>.from(result);
  }

  SupabaseClient get _client => _injectedClient ?? Supabase.instance.client;

  /// ترجمة أخطاء PostgREST/الشبكة إلى رسائل عربية مفهومة للمستخدم
  String friendlyError(Object e) {
    final raw = e.toString();
    if (raw.contains('active dispute already exists')) {
      return 'لديك طلب سابق لهذه العملية. افتح «طلباتي للتاجر» لمتابعته.';
    }
    if (raw.contains('Dispute is already resolved')) {
      return 'تم إغلاق الاعتراض. حدّث الصفحة لعرض النتيجة؛ لم يُرسل الرد.';
    }
    if (raw.contains('Cannot dispute a reversed entry')) {
      return 'تم تصحيح هذه العملية وعكس أثرها. حدّث الكشف لمراجعة القيد التصحيحي.';
    }
    if (raw.contains('Not authorized or entry unavailable')) {
      return 'تغير ارتباط الحساب أو لم تعد العملية متاحة. حدّث بياناتك قبل إعادة المحاولة.';
    }
    if (e is TimeoutException) {
      return 'انتهت مهلة الاتصال. حدّث البيانات للتحقق من النتيجة قبل إعادة العملية.';
    }
    final msg = e.toString();
    if (msg.contains('PGRST202')) {
      return 'عقد غير متطابق مع الخادم — حدّث التطبيق أو تواصل مع الدعم';
    }
    if (msg.contains('42501')) {
      return 'ليست لديك صلاحية لتنفيذ هذه العملية';
    }
    if (msg.contains('42703')) {
      return 'البيانات غير متزامنة مع الخادم — أعد المحاولة بعد المزامنة';
    }
    if (msg.contains('SocketException') ||
        msg.contains('Failed host lookup') ||
        msg.contains('ClientException')) {
      return 'تعذر الاتصال بالخادم — تحقق من اتصالك بالإنترنت';
    }
    if (e is PostgrestException && e.message.isNotEmpty) {
      return e.message;
    }
    if (e is FunctionException) {
      return 'تعذر تنفيذ العملية على الخادم — حاول مرة أخرى';
    }
    return msg.length > 180 ? '${msg.substring(0, 180)}…' : msg;
  }

  /// حل هوية العميل: سجل `customers` المرتبط بالمستخدم الحالي.
  /// يعيد null عند غياب السجل (حالة «لا حساب عميل مرتبط» وليست خطأً).
  Future<String?> resolveCustomerId() async {
    _requireOnlineSession();
    final user = _client.auth.currentUser;
    if (user == null) return null;
    try {
      final row = await _client
          .from('customers')
          .select('id')
          .eq('user_id', user.id)
          .maybeSingle()
          .timeout(const Duration(seconds: 15));
      return row?['id'] as String?;
    } catch (e) {
      throw Exception(friendlyError(e));
    }
  }

  /// الملخص المالي الحقيقي: صفوف المحلات المرتبطة مفصولة بالعملة.
  /// RLS على العرض تضمن أن العميل يرى روابطه `linked` فقط.
  Future<List<CustomerBusinessSummary>> fetchBusinessSummaries(
    String customerId,
  ) async => (await fetchHomeSnapshot()).summaries;
  Future<List<CustomerLinkRequestModel>> fetchPendingLinkRequests(
    String customerId,
  ) async => (await fetchHomeSnapshot()).requests;
  Future<List<CustomerPendingEntry>> fetchPendingEntries(
    String customerId,
  ) async => (await fetchHomeSnapshot()).entries
      .map(CustomerPendingEntry.fromMap)
      .toList();
  Future<void> respondLinkRequest({
    required String requestId,
    required bool accept,
  }) async {
    await _enqueue({'kind': 'link', 'target_id': requestId, 'accept': accept});
  }

  /// حفظ طلب التأكيد محليًا؛ لا يتغير التأكيد النهائي قبل قبول الخادم.
  Future<void> confirmEntry(String entryId) async {
    await _enqueue({'kind': 'confirm', 'target_id': entryId});
  }

  /// فتح اعتراض على قيد مالي. لا يغيّر القيد أو الرصيد؛ دورة الاعتراض
  /// وحلّه تتم عبر أوامر الخادم وسجل الأحداث غير القابل للمحو.
  Future<void> openDispute({
    required String entryId,
    required String reason,
    required String description,
  }) async {
    if (description.trim().isEmpty || description.length > 4000) {
      throw ArgumentError('اكتب توضيحًا بين 1 و4000 حرف');
    }
    await _enqueue({
      'kind': 'dispute',
      'target_id': entryId,
      'reason': reason,
      'description': description.trim(),
    });
  }
}
