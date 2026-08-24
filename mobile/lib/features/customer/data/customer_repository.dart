import 'package:supabase_flutter/supabase_flutter.dart';
import 'models/customer_summary_model.dart';

/// طبقة بيانات شاشة العميل — قراءة مباشرة من عروض Supabase العامة المحمية بـ RLS
/// (`customer_business_summary`, `customer_link_requests`, `ledger_timeline`)
/// وأوامر العميل العامة (`respond_link_request`, `confirm_ledger_entry`).
///
/// ممنوع الابتلاع الصامت للأخطاء: كل فشل يُرمى برسالة عربية واضحة تعرضها الواجهة.
class CustomerRepository {
  SupabaseClient get _client => Supabase.instance.client;

  /// ترجمة أخطاء PostgREST/الشبكة إلى رسائل عربية مفهومة للمستخدم
  String friendlyError(Object e) {
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
    final user = _client.auth.currentUser;
    if (user == null) return null;
    try {
      final row = await _client
          .from('customers')
          .select('id')
          .eq('user_id', user.id)
          .maybeSingle();
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
    try {
      final res = await _client
          .from('customer_business_summary')
          .select(
            'business_customer_id, business_id, business_name, business_type, '
            'currency_code, current_balance, entry_count, last_entry_at',
          )
          .eq('customer_id', customerId);
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
    try {
      final res = await _client
          .from('customer_link_requests')
          .select(
            'id, status, created_at, '
            'business_customers(local_display_name, businesses(name, city))',
          )
          .eq('target_customer_id', customerId)
          .eq('status', 'pending')
          .order('created_at', ascending: false);
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
    try {
      final res = await _client
          .from('ledger_timeline')
          .select(
            'id, business_customer_id, entry_type, direction, amount, '
            'currency_code, description, occurred_at',
          )
          .eq('customer_id', customerId)
          .eq('confirmation_status', 'pending')
          .order('occurred_at', ascending: false);
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
    try {
      await _client.rpc(
        'respond_link_request',
        params: {'p_request_id': requestId, 'p_accept': accept},
      );
    } catch (e) {
      throw Exception(friendlyError(e));
    }
  }

  /// تأكيد قيد مالي (أونلاين) عبر الأمر العام confirm_ledger_entry.
  /// ملاحظة: الإدراج في طابور الأوفلاين (enqueueMutation) اعتمادية على مالك core —
  /// عند غياب الشبكة يظهر للمستخدم خطأ واضح بدل الصمت.
  Future<void> confirmEntry(String entryId) async {
    try {
      await _client.rpc(
        'confirm_ledger_entry',
        params: {'p_entry_id': entryId, 'p_device_id': null},
      );
    } catch (e) {
      throw Exception(friendlyError(e));
    }
  }

  /// فتح اعتراض على قيد مالي. لا يغيّر القيد أو الرصيد؛ دورة الاعتراض
  /// وحلّه تتم عبر أوامر الخادم وسجل الأحداث غير القابل للمحو.
  Future<void> openDispute({
    required String entryId,
    required String reason,
    required String description,
  }) async {
    try {
      await _client.rpc(
        'open_dispute',
        params: {
          'p_entry_id': entryId,
          'p_reason': reason,
          'p_description': description.trim(),
        },
      );
    } catch (e) {
      throw Exception(friendlyError(e));
    }
  }
}
