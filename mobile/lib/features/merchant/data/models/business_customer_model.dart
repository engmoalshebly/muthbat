class BusinessCustomerModel {
  final String id;
  final String businessId;
  final String? customerId;
  final String localDisplayName;
  final String? localNote;
  final String? phone;
  final double? creditLimit;
  final int? defaultDueDays;
  final String linkStatus; // 'unlinked', 'pending', 'linked', 'rejected'
  final double currentBalance;
  final double amountCustomerOwes;
  final double amountBusinessOwesCustomer;
  final double overdueBalance;
  final Map<String, double>
  currencyBalances; // e.g. {'YER': 50000.0, 'SAR': 500.0, 'USD': 0.0}
  final bool isArchived;
  final String syncStatus;
  final String? createdAt;
  final String? updatedAt;

  const BusinessCustomerModel({
    required this.id,
    required this.businessId,
    this.customerId,
    required this.localDisplayName,
    this.localNote,
    this.phone,
    this.creditLimit,
    this.defaultDueDays,
    this.linkStatus = 'unlinked',
    this.currentBalance = 0.0,
    this.amountCustomerOwes = 0.0,
    this.amountBusinessOwesCustomer = 0.0,
    this.overdueBalance = 0.0,
    this.currencyBalances = const {},
    this.isArchived = false,
    this.syncStatus = 'synced',
    this.createdAt,
    this.updatedAt,
  });

  BusinessCustomerModel copyWith({
    Map<String, double>? currencyBalances,
    double? currentBalance,
    double? amountCustomerOwes,
    double? amountBusinessOwesCustomer,
    double? overdueBalance,
  }) {
    return BusinessCustomerModel(
      id: id,
      businessId: businessId,
      customerId: customerId,
      localDisplayName: localDisplayName,
      localNote: localNote,
      phone: phone,
      creditLimit: creditLimit,
      defaultDueDays: defaultDueDays,
      linkStatus: linkStatus,
      currentBalance: currentBalance ?? this.currentBalance,
      amountCustomerOwes: amountCustomerOwes ?? this.amountCustomerOwes,
      amountBusinessOwesCustomer:
          amountBusinessOwesCustomer ?? this.amountBusinessOwesCustomer,
      overdueBalance: overdueBalance ?? this.overdueBalance,
      currencyBalances: currencyBalances ?? this.currencyBalances,
      isArchived: isArchived,
      syncStatus: syncStatus,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  factory BusinessCustomerModel.fromMap(
    Map<String, dynamic> map, [
    Map<String, double>? currencyBalances,
  ]) {
    return BusinessCustomerModel(
      id: map['id'] as String,
      businessId: map['business_id'] as String,
      customerId: map['customer_id'] as String?,
      localDisplayName: map['local_display_name'] as String,
      localNote: map['local_note'] as String?,
      phone: map['phone'] as String?,
      creditLimit: (map['credit_limit'] as num?)?.toDouble(),
      defaultDueDays: map['default_due_days'] as int?,
      linkStatus: map['link_status'] as String? ?? 'unlinked',
      currentBalance: (map['current_balance'] as num?)?.toDouble() ?? 0.0,
      amountCustomerOwes:
          (map['amount_customer_owes'] as num?)?.toDouble() ?? 0.0,
      amountBusinessOwesCustomer:
          (map['amount_business_owes_customer'] as num?)?.toDouble() ?? 0.0,
      overdueBalance:
          (map['overdue_balance'] as num?)?.toDouble() ??
          (map['gross_overdue_debits'] as num?)?.toDouble() ??
          0.0,
      currencyBalances: currencyBalances ?? const {},
      isArchived: (map['is_archived'] is int)
          ? (map['is_archived'] == 1)
          : (map['is_archived'] as bool? ?? false),
      syncStatus: map['sync_status'] as String? ?? 'synced',
      createdAt: map['created_at'] as String?,
      updatedAt: map['updated_at'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'business_id': businessId,
      'customer_id': customerId,
      'local_display_name': localDisplayName,
      'local_note': localNote,
      'phone': phone,
      'credit_limit': creditLimit,
      'default_due_days': defaultDueDays,
      'link_status': linkStatus,
      'current_balance': currentBalance,
      'amount_customer_owes': amountCustomerOwes,
      'amount_business_owes_customer': amountBusinessOwesCustomer,
      'overdue_balance': overdueBalance,
      'is_archived': isArchived ? 1 : 0,
      'sync_status': syncStatus,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }
}
