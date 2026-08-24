/// عقد RPC المركزي لميزة التاجر — المصدر الوحيد لأسماء الدوال ومفاتيح الحمولات.
///
/// المرجع الملزم: `fix-plan/02-rpc-contract.md` §1.1 (العقد الموحد v1)
import '../../../../core/finance/money.dart';

/// وقرارات `fix-plan.md` (القرار 1: لا يُرسل العميل p_currency_code؛
/// القرار 4: إضافة العميل عبر Edge Function ‏customer-directory).
///
/// ملاحظة ملكية: الخطة تقترح موضعاً عاماً `core/api/rpc_contract.dart`
/// (خطة 02 خطوة 4) يملكه وكيل آخر ضمن core. هذه النسخة محلية لمجلد
/// بيانات التاجر إلى أن يصل الملف العام، وعندها تُستبدل هذه المراجع به.
class RpcContract {
  RpcContract._();

  /// نسخة العقد الموحد — تُرفع مع أي تغيير في الباكند (خطة 02 §4.2).
  static const String contractVersion = '1.0.0';

  // ==================== أسماء دوال RPC العامة (schema public) ====================
  // ممنوع استدعاء دوال private.* من العميل إطلاقاً (غير مكشوفة عبر PostgREST).
  static const String createBusiness = 'create_business';
  static const String updateBusinessCurrencies = 'update_business_currencies';
  static const String createLedgerEntry = 'create_ledger_entry';
  static const String applyCustomerDiscount = 'apply_customer_discount';
  static const String reverseLedgerEntry = 'reverse_ledger_entry';
  static const String confirmLedgerEntry = 'confirm_ledger_entry';
  static const String openDispute = 'open_dispute';
  static const String addDisputeMessage = 'add_dispute_message';
  static const String resolveDispute = 'resolve_dispute';
  static const String inviteBusinessMember = 'invite_business_member';
  static const String respondBusinessMemberInvite =
      'respond_business_member_invite';
  static const String createStatement = 'create_statement';
  static const String requestCustomerLink = 'request_customer_link';
  static const String respondLinkRequest = 'respond_link_request';
  static const String createBusinessCustomerDirect =
      'create_business_customer_direct';

  // ==================== Edge Functions ====================
  static const String edgeCustomerDirectory = 'customer-directory';

  // ==================== أنواع أوامر طابور المزامنة ====================
  static const String cmdCreateBusiness = 'create_business';
  static const String cmdCreateLedgerEntry = 'create_ledger_entry';
  static const String cmdApplyCustomerDiscount = 'apply_customer_discount';
  static const String cmdReverseLedgerEntry = 'reverse_ledger_entry';

  /// أمر إضافة عميل عبر customer-directory (نمط pending_directory — خطة 06 خطوة 5.6).
  /// معالج هذا النوع في محرك المزامنة يملكه وكيل المزامنة؛ عند نجاحه يجب أن
  /// يستدعي [MerchantRepository.reconcileBusinessCustomerId] بالمعرّف الخادمي.
  static const String cmdCustomerDirectory = 'customer_directory';
  static const String cmdGenerateStatement = 'generate_statement';
  static const String cmdUpdateBusinessProfile = 'update_business_profile';

  /// حمولة `create_ledger_entry` بالتوقيع الموسع (ترحيل توحيد العقد 0013/0014):
  /// `(p_business_customer_id, p_entry_type, p_amount, p_description,
  ///   p_category, p_payment_method, p_reference_number, p_bank_or_agent_name,
  ///   p_attachment_url, p_occurred_at, p_due_date, p_external_reference,
  ///   p_client_request_id, p_source_device_id)`
  ///
  /// العملة تُشتق خلفياً من `businesses.currency_code` — ممنوع إرسال
  /// `p_currency_code` (قرار كبير المعماريين رقم 1).
  static Map<String, dynamic> createLedgerEntryPayload({
    required String businessCustomerId,
    required String entryType,
    required double amount,
    required String description,
    required String category,
    required String paymentMethod,
    required String occurredAt,
    required String clientRequestId,
    String? referenceNumber,
    String? bankOrAgentName,
    String? attachmentUrl,
    String? dueDate,
    String? externalReference,
    String? sourceDeviceId,
    String? currencyCode,
  }) {
    return {
      'p_business_customer_id': businessCustomerId,
      'p_entry_type': entryType,
      'p_amount': Money.fromNum(amount).toDecimalString(),
      'p_description': description,
      'p_category': category,
      'p_payment_method': paymentMethod,
      'p_reference_number': referenceNumber,
      'p_bank_or_agent_name': bankOrAgentName,
      'p_attachment_url': attachmentUrl,
      'p_occurred_at': occurredAt,
      'p_due_date': dueDate,
      'p_external_reference': externalReference,
      'p_client_request_id': clientRequestId,
      'p_source_device_id': sourceDeviceId,
      'p_currency_code': currencyCode?.toUpperCase(),
    };
  }

  /// حمولة `apply_customer_discount`:
  /// `(p_business_customer_id, p_amount, p_description, p_client_request_id)`
  /// بلا أي معامل عملة (الخصم بعملة المحل حصراً — خطة 02 §1.2-ج).
  static Map<String, dynamic> applyCustomerDiscountPayload({
    required String businessCustomerId,
    required double amount,
    required String description,
    required String clientRequestId,
    String? currencyCode,
  }) {
    return {
      'p_business_customer_id': businessCustomerId,
      'p_amount': Money.fromNum(amount).toDecimalString(),
      'p_description': description,
      'p_client_request_id': clientRequestId,
      'p_currency_code': currencyCode?.toUpperCase(),
    };
  }

  /// حمولة `reverse_ledger_entry`:
  /// `(p_entry_id, p_reason, p_client_request_id)` — المعامل الخلفي الفعلي
  /// هو `p_entry_id` وليس `p_original_entry_id` (خطة 02 خطوة 1).
  static Map<String, dynamic> reverseLedgerEntryPayload({
    required String entryId,
    required String reason,
    required String clientRequestId,
  }) {
    return {
      'p_entry_id': entryId,
      'p_reason': reason,
      'p_client_request_id': clientRequestId,
    };
  }

  /// جسم استدعاء Edge Function ‏`customer-directory` (خطة 06-D4).
  ///
  /// [localCustomerId] يُستخدم فقط عند تخزين الجسم في طابور الأوفلاين لغرض
  /// تسوية المعرّفات لاحقاً؛ الدالة الخلفية تتجاهله.
  static Map<String, dynamic> customerDirectoryBody({
    required String businessId,
    required String phone,
    required String localDisplayName,
    double? creditLimit,
    int? defaultDueDays,
    bool requestLink = true,
    String? localCustomerId,
  }) {
    return {
      'businessId': businessId,
      'phone': phone,
      'localDisplayName': localDisplayName,
      'creditLimit': ?(creditLimit == null
          ? null
          : Money.fromNum(creditLimit).toDecimalString()),
      'defaultDueDays': ?defaultDueDays,
      'requestLink': requestLink,
      'localCustomerId': ?localCustomerId,
    };
  }
}
