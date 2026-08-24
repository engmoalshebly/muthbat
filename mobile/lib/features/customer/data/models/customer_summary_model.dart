/// نماذج بيانات شاشة العميل — تقرأ من عروض Supabase العامة
/// (`customer_business_summary`, `customer_link_requests`, `ledger_timeline`).

/// ملخص علاقة العميل بمحل واحد بعملة واحدة (صف من عرض customer_business_summary)
class CustomerBusinessSummary {
  final String businessCustomerId;
  final String businessId;
  final String businessName;
  final String? businessType;
  final String currencyCode;
  final double
  currentBalance; // موجب = على العميل (مستحق عليه)، سالب = له مبلغ مقدم
  final int entryCount;
  final String? lastEntryAt;

  const CustomerBusinessSummary({
    required this.businessCustomerId,
    required this.businessId,
    required this.businessName,
    this.businessType,
    required this.currencyCode,
    required this.currentBalance,
    required this.entryCount,
    this.lastEntryAt,
  });

  factory CustomerBusinessSummary.fromMap(Map<String, dynamic> map) {
    return CustomerBusinessSummary(
      businessCustomerId: map['business_customer_id'] as String,
      businessId: map['business_id'] as String,
      businessName: map['business_name'] as String? ?? 'محل تجاري',
      businessType: map['business_type'] as String?,
      currencyCode: (map['currency_code'] as String?)?.toUpperCase() ?? 'YER',
      currentBalance: (map['current_balance'] as num?)?.toDouble() ?? 0.0,
      entryCount: (map['entry_count'] as num?)?.toInt() ?? 0,
      lastEntryAt: map['last_entry_at'] as String?,
    );
  }
}

/// طلب ربط حساب معلق موجه للعميل (صف من customer_link_requests)
class CustomerLinkRequestModel {
  final String id;
  final String status;
  final String? createdAt;
  final String businessName;
  final String? businessCity;
  final String localDisplayName;

  const CustomerLinkRequestModel({
    required this.id,
    required this.status,
    this.createdAt,
    required this.businessName,
    this.businessCity,
    required this.localDisplayName,
  });

  factory CustomerLinkRequestModel.fromMap(Map<String, dynamic> map) {
    final bc = map['business_customers'] as Map<String, dynamic>?;
    final biz = bc?['businesses'] as Map<String, dynamic>?;
    return CustomerLinkRequestModel(
      id: map['id'] as String,
      status: map['status'] as String? ?? 'pending',
      createdAt: map['created_at'] as String?,
      businessName: biz?['name'] as String? ?? 'محل تجاري',
      businessCity: biz?['city'] as String?,
      localDisplayName: bc?['local_display_name'] as String? ?? '',
    );
  }
}

/// قيد مالي بانتظار تأكيد العميل (صف من عرض ledger_timeline)
class CustomerPendingEntry {
  final String id;
  final String businessCustomerId;
  final String entryType; // 'debt', 'payment', 'discount', ...
  final String direction; // 'debit', 'credit'
  final double amount;
  final String currencyCode;
  final String description;
  final String occurredAt;

  const CustomerPendingEntry({
    required this.id,
    required this.businessCustomerId,
    required this.entryType,
    required this.direction,
    required this.amount,
    required this.currencyCode,
    required this.description,
    required this.occurredAt,
  });

  factory CustomerPendingEntry.fromMap(Map<String, dynamic> map) {
    return CustomerPendingEntry(
      id: map['id'] as String,
      businessCustomerId: map['business_customer_id'] as String,
      entryType: map['entry_type'] as String? ?? 'debt',
      direction: map['direction'] as String? ?? 'debit',
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      currencyCode: (map['currency_code'] as String?)?.toUpperCase() ?? 'YER',
      description: map['description'] as String? ?? '',
      occurredAt: map['occurred_at'] as String? ?? '',
    );
  }
}
