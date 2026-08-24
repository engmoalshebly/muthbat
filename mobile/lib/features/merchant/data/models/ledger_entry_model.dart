class LedgerEntryModel {
  final String id;
  final String businessId;
  final String businessCustomerId;
  final String? customerId;
  final String
  entryType; // 'debt', 'payment', 'discount', 'opening_balance', 'reversal'
  final String direction; // 'debit', 'credit'
  final double amount;
  final String currencyCode;
  final String category; // 'goods', 'cash', 'service', 'transfer', 'other'
  final String paymentMethod; // 'cash', 'bank_transfer', 'cheque', 'offset'
  final String? referenceNumber;
  final String? bankOrAgentName;
  final String? attachmentPath;
  final String description;
  final String occurredAt;
  final String? dueDate;
  final String? externalReference;
  final String clientRequestId;
  final String confirmationStatus; // 'not_available', 'pending', 'confirmed'
  final String disputeStatus; // 'none', 'open', 'resolved'
  final bool isReversed;
  final String syncStatus; // 'synced', 'pending_insert', 'failed'
  final String? createdAt;

  const LedgerEntryModel({
    required this.id,
    required this.businessId,
    required this.businessCustomerId,
    this.customerId,
    required this.entryType,
    required this.direction,
    required this.amount,
    this.currencyCode = 'YER',
    this.category = 'goods',
    this.paymentMethod = 'cash',
    this.referenceNumber,
    this.bankOrAgentName,
    this.attachmentPath,
    required this.description,
    required this.occurredAt,
    this.dueDate,
    this.externalReference,
    required this.clientRequestId,
    this.confirmationStatus = 'not_available',
    this.disputeStatus = 'none',
    this.isReversed = false,
    this.syncStatus = 'synced',
    this.createdAt,
  });

  factory LedgerEntryModel.fromMap(Map<String, dynamic> map) {
    return LedgerEntryModel(
      id: map['id'] as String,
      businessId: map['business_id'] as String,
      businessCustomerId: map['business_customer_id'] as String,
      customerId: map['customer_id'] as String?,
      entryType: map['entry_type'] as String,
      direction: map['direction'] as String,
      amount: (map['amount'] as num).toDouble(),
      currencyCode: (map['currency_code'] as String?)?.toUpperCase() ?? 'YER',
      category: map['category'] as String? ?? 'goods',
      paymentMethod: map['payment_method'] as String? ?? 'cash',
      referenceNumber: map['reference_number'] as String?,
      bankOrAgentName: map['bank_or_agent_name'] as String?,
      attachmentPath:
          (map['attachment_path'] ?? map['attachment_url']) as String?,
      description: map['description'] as String? ?? '',
      occurredAt:
          map['occurred_at'] as String? ?? DateTime.now().toIso8601String(),
      dueDate: map['due_date'] as String?,
      externalReference: map['external_reference'] as String?,
      clientRequestId: map['client_request_id'] as String? ?? '',
      confirmationStatus:
          map['confirmation_status'] as String? ?? 'not_available',
      disputeStatus: map['dispute_status'] as String? ?? 'none',
      isReversed: (map['is_reversed'] is int)
          ? (map['is_reversed'] == 1)
          : (map['is_reversed'] as bool? ?? false),
      syncStatus: map['sync_status'] as String? ?? 'synced',
      createdAt: map['created_at'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'business_id': businessId,
      'business_customer_id': businessCustomerId,
      'customer_id': customerId,
      'entry_type': entryType,
      'direction': direction,
      'amount': amount,
      'currency_code': currencyCode,
      'category': category,
      'payment_method': paymentMethod,
      'reference_number': referenceNumber,
      'bank_or_agent_name': bankOrAgentName,
      'attachment_path': attachmentPath,
      'description': description,
      'occurred_at': occurredAt,
      'due_date': dueDate,
      'external_reference': externalReference,
      'client_request_id': clientRequestId,
      'confirmation_status': confirmationStatus,
      'dispute_status': disputeStatus,
      'is_reversed': isReversed ? 1 : 0,
      'sync_status': syncStatus,
      'created_at': createdAt,
    };
  }
}
