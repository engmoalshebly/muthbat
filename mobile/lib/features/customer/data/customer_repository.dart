import 'dart:async';
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'models/customer_summary_model.dart';
import 'customer_outbox.dart';
import '../../../core/database/app_database.dart';

/// طبقة بيانات شاشة العميل — قراءة مباشرة من عروض Supabase العامة المحمية بـ RLS
/// (`customer_business_summary`, `customer_link_requests`, `ledger_timeline`)
/// وأوامر العميل العامة (`respond_link_request`, `confirm_ledger_entry`).
///
/// ممنوع الابتلاع الصامت للأخطاء: كل فشل يُرمى برسالة عربية واضحة تعرضها الواجهة.
class CustomerRepository {
  final _outbox = CustomerOutbox();
  bool _flushing = false;

  Future<List<Map<String, dynamic>>> pendingActions() async =>
      userId == null ? [] : _outbox.list(userId!);

  Future<void> retryAction(String id) async {
    if (userId != null) await _outbox.retry(userId!, id);
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
      for (final action
          in pending.where((e) => e['status'] == 'pending').take(1)) {
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
          if (['P0001', '22023', '22P02', '23505', '42501'].contains(e.code)) {
            await _outbox.fail(owner, action['id'] as String, friendlyError(e));
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

  String? get userId =>
      _client.auth.currentUser?.id ?? AppDatabase.instance.accountId;

  void _requireOnlineSession() {
    final session = _client.auth.currentSession;
    if (session == null || session.isExpired || session.user.id != userId) {
      throw StateError(
        'بياناتك المحفوظة متاحة. اتصل بالإنترنت وسجّل الدخول لاستكمال التحديث أو إرسال العمليات.',
      );
    }
  }

  Future<void> refreshPhoneLinks() async {
    _requireOnlineSession();
    try {
      await _client.functions
          .invoke('bootstrap-user-contact')
          .timeout(const Duration(seconds: 15));
    } on FunctionException catch (e) {
      if (e.status == 403 || e.status == 422) {
        throw Exception(
          'يلزم التحقق الفعلي من ملكية رقم الهاتف. حساب الاختبار دون رمز تحقق لا يربط سجلات البقالات.',
        );
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
          'id,business_customer_id,entry_type,direction,amount,currency_code,description,occurred_at,confirmation_status,dispute_status,is_reversed',
        )
        .eq('business_customer_id', businessCustomerId)
        .eq('currency_code', currency)
        .order('occurred_at', ascending: false)
        .order('id', ascending: false)
        .range(offset, offset + 49)
        .timeout(const Duration(seconds: 15));
    return List<Map<String, dynamic>>.from(result);
  }

  SupabaseClient get _client => Supabase.instance.client;

  /// ترجمة أخطاء PostgREST/الشبكة إلى رسائل عربية مفهومة للمستخدم
  String friendlyError(Object e) {
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
  ) async {
    _requireOnlineSession();
    try {
      final res = await _client
          .from('customer_business_summary')
          .select(
            'business_customer_id, business_id, business_name, business_type, '
            'currency_code, current_balance, entry_count, last_entry_at',
          )
          .eq('customer_id', customerId)
          .timeout(const Duration(seconds: 15));
      return (res as List)
          .map(
            (row) =>
                CustomerBusinessSummary.fromMap(row as Map<String, dynamic>),
          )
          .toList();
    } catch (e) {
      throw Exception(friendlyError(e));
    }
  }

  /// طلبات الربط المعلقة الموجهة لهذا العميل مع اسم المحل ومدينته.
  Future<List<CustomerLinkRequestModel>> fetchPendingLinkRequests(
    String customerId,
  ) async {
    _requireOnlineSession();
    try {
      final res = await _client
          .rpc('customer_pending_link_requests')
          .timeout(const Duration(seconds: 15));
      return (res as List)
          .map(
            (row) =>
                CustomerLinkRequestModel.fromMap(row as Map<String, dynamic>),
          )
          .toList();
    } catch (e) {
      throw Exception(friendlyError(e));
    }
  }

  /// القيود المالية بانتظار تأكيد العميل (من عرض ledger_timeline).
  Future<List<CustomerPendingEntry>> fetchPendingEntries(
    String customerId,
  ) async {
    _requireOnlineSession();
    try {
      final res = await _client
          .from('ledger_timeline')
          .select(
            'id, business_customer_id, entry_type, direction, amount, '
            'currency_code, description, occurred_at',
          )
          .eq('customer_id', customerId)
          .eq('confirmation_status', 'pending')
          .eq('is_reversed', false)
          .eq('dispute_status', 'none')
          .order('occurred_at', ascending: false)
          .timeout(const Duration(seconds: 15));
      return (res as List)
          .map(
            (row) => CustomerPendingEntry.fromMap(row as Map<String, dynamic>),
          )
          .toList();
    } catch (e) {
      throw Exception(friendlyError(e));
    }
  }

  /// الرد على طلب ربط (قبول/رفض) عبر الأمر العام respond_link_request.
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
