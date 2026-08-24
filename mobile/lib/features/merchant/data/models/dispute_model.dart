class DisputeModel {
  final String id;
  final String entryId;
  final String businessId;
  final String customerId;
  final String reason; // 'incorrect_amount', 'duplicate_entry', 'unrecognized_transaction', 'goods_not_received', 'payment_not_reflected', 'other'
  final String description;
  final String status; // 'awaiting_merchant', 'awaiting_customer', 'accepted', 'partially_accepted', 'rejected', 'escalated'
  final String? resolutionNote;
  final String? resolvedAt;
  final String? createdAt;

  // حقول مساعدة من العلاقات للعرض في الواجهة
  final String? customerDisplayName;
  final String? customerPhone;
  final String? customerGlobalCode;
  final double? entryAmount;
  final String? entryDescription;
  final String? entryType;
  final String? entryOccurredAt;

  const DisputeModel({
    required this.id,
    required this.entryId,
    required this.businessId,
    required this.customerId,
    required this.reason,
    required this.description,
    this.status = 'awaiting_merchant',
    this.resolutionNote,
    this.resolvedAt,
    this.createdAt,
    this.customerDisplayName,
    this.customerPhone,
    this.customerGlobalCode,
    this.entryAmount,
    this.entryDescription,
    this.entryType,
    this.entryOccurredAt,
  });

  factory DisputeModel.fromMap(Map<String, dynamic> map) {
    // معالجة البيانات المدمجة من الـ joins
    final entry = map['ledger_entries'] as Map<String, dynamic>?;
    // اسم العميل يُقرأ من المسار المتداخل ledger_entries→business_customers
    // (لا يوجد FK باسم profiles!customer_id — خطة 06 خطوة 3.3)
    final entryCustomer = entry?['business_customers'] as Map<String, dynamic>?;
    final customer = map['customers'] as Map<String, dynamic>?;
    final state = map['dispute_state'] is List && (map['dispute_state'] as List).isNotEmpty
        ? (map['dispute_state'] as List).first as Map<String, dynamic>
        : (map['dispute_state'] as Map<String, dynamic>?);

    return DisputeModel(
      id: map['id'] as String,
      entryId: map['entry_id'] as String,
      businessId: map['business_id'] as String,
      customerId: map['customer_id'] as String,
      reason: map['reason'] as String? ?? 'other',
      description: map['description'] as String? ?? '',
      status: (state != null ? state['status'] : map['status']) as String? ?? 'awaiting_merchant',
      resolutionNote: (state != null ? state['resolution_note'] : map['resolution_note']) as String?,
      resolvedAt: (state != null ? state['resolved_at'] : map['resolved_at']) as String?,
      createdAt: map['created_at'] as String?,
      customerDisplayName: entryCustomer?['local_display_name'] as String? ??
          map['local_display_name'] as String? ??
          (customer != null ? customer['full_name'] as String? : null),
      customerPhone: map['phone'] as String?,
      customerGlobalCode: (customer != null ? customer['global_code'] as String? : null) ??
          map['global_code'] as String?,
      entryAmount: entry != null ? (entry['amount'] as num?)?.toDouble() : (map['entry_amount'] as num?)?.toDouble(),
      entryDescription: entry != null ? entry['description'] as String? : map['entry_description'] as String?,
      entryType: entry != null ? entry['entry_type'] as String? : map['entry_type'] as String?,
      entryOccurredAt: entry != null ? entry['occurred_at'] as String? : map['entry_occurred_at'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'entry_id': entryId,
      'business_id': businessId,
      'customer_id': customerId,
      'reason': reason,
      'description': description,
      'status': status,
      'resolution_note': resolutionNote,
      'resolved_at': resolvedAt,
      'created_at': createdAt,
    };
  }

  bool get isOpen => status == 'awaiting_merchant' || status == 'awaiting_customer' || status == 'open' || status == 'escalated';
  bool get isResolved => status == 'accepted' || status == 'partially_accepted' || status == 'rejected';

  String get reasonLocalized {
    switch (reason) {
      // قيم enum الباكند dispute_reason السبع (0001:24) — ملاحظة L-1
      case 'wrong_amount':
        return 'المبلغ غير صحيح';
      case 'unknown_transaction':
        return 'عملية غير معروفة';
      case 'duplicate':
        return 'عملية مكررة';
      case 'already_paid':
        return 'تم سدادها مسبقاً';
      case 'wrong_date':
        return 'التاريخ غير صحيح';
      case 'wrong_description':
        return 'الوصف غير صحيح';
      // قيم قديمة محلية (كاش) — تُبقى للتوافق ولا تُرسل للخادم
      case 'incorrect_amount':
        return 'المبلغ غير صحيح';
      case 'duplicate_entry':
        return 'عملية مكررة';
      case 'unrecognized_transaction':
        return 'عملية غير معروفة';
      case 'goods_not_received':
        return 'لم يتم استلام البضاعة';
      case 'payment_not_reflected':
        return 'السداد لم يُحتسب';
      case 'other':
      default:
        return 'سبب آخر';
    }
  }

  String get statusLocalized {
    switch (status) {
      case 'awaiting_merchant':
        return 'بانتظار رد التاجر';
      case 'awaiting_customer':
        return 'بانتظار رد العميل';
      case 'accepted':
        return 'تم القبول (معكوس)';
      case 'partially_accepted':
        return 'تم القبول الجزئي';
      case 'rejected':
        return 'تم الرفض';
      case 'escalated':
        return 'مُصعّد للإدارة';
      case 'open':
      default:
        return 'مفتوح';
    }
  }
}
