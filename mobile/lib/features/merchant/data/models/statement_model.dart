class StatementModel {
  final String id;
  final String scope; // 'business_customer' | 'customer_consolidated'
  final String? businessId;
  final String? businessCustomerId;
  final String? customerId;
  final String periodFrom;
  final String periodTo;
  final String currencyCode;
  final double openingBalance;
  final double totalDebits;
  final double totalCredits;
  final double closingBalance;
  final String verificationCode;
  final String? pdfObjectPath;
  final String? snapshotSha256Hex;
  final String? createdAt;
  final String? downloadUrl;

  const StatementModel({
    required this.id,
    required this.scope,
    this.businessId,
    this.businessCustomerId,
    this.customerId,
    required this.periodFrom,
    required this.periodTo,
    this.currencyCode = 'YER',
    required this.openingBalance,
    required this.totalDebits,
    required this.totalCredits,
    required this.closingBalance,
    required this.verificationCode,
    this.pdfObjectPath,
    this.snapshotSha256Hex,
    this.createdAt,
    this.downloadUrl,
  });

  factory StatementModel.fromMap(Map<String, dynamic> map, {String? downloadUrl}) {
    return StatementModel(
      id: map['id'] as String,
      scope: map['scope'] as String? ?? 'business_customer',
      businessId: map['business_id'] as String?,
      businessCustomerId: map['business_customer_id'] as String?,
      customerId: map['customer_id'] as String?,
      periodFrom: map['period_from'] as String,
      periodTo: map['period_to'] as String,
      currencyCode: map['currency_code'] as String? ?? 'YER',
      openingBalance: (map['opening_balance'] as num?)?.toDouble() ?? 0.0,
      totalDebits: (map['total_debits'] as num?)?.toDouble() ?? 0.0,
      totalCredits: (map['total_credits'] as num?)?.toDouble() ?? 0.0,
      closingBalance: (map['closing_balance'] as num?)?.toDouble() ?? 0.0,
      verificationCode: map['verification_code'] as String? ?? '',
      pdfObjectPath: map['pdf_object_path'] as String?,
      snapshotSha256Hex: map['snapshot_sha256_hex'] as String?,
      createdAt: map['created_at'] as String?,
      downloadUrl: downloadUrl ?? map['downloadUrl'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'scope': scope,
      'business_id': businessId,
      'business_customer_id': businessCustomerId,
      'customer_id': customerId,
      'period_from': periodFrom,
      'period_to': periodTo,
      'currency_code': currencyCode,
      'opening_balance': openingBalance,
      'total_debits': totalDebits,
      'total_credits': totalCredits,
      'closing_balance': closingBalance,
      'verification_code': verificationCode,
      'pdf_object_path': pdfObjectPath,
      'snapshot_sha256_hex': snapshotSha256Hex,
      'created_at': createdAt,
    };
  }

  StatementModel copyWith({String? downloadUrl}) {
    return StatementModel(
      id: id,
      scope: scope,
      businessId: businessId,
      businessCustomerId: businessCustomerId,
      customerId: customerId,
      periodFrom: periodFrom,
      periodTo: periodTo,
      currencyCode: currencyCode,
      openingBalance: openingBalance,
      totalDebits: totalDebits,
      totalCredits: totalCredits,
      closingBalance: closingBalance,
      verificationCode: verificationCode,
      pdfObjectPath: pdfObjectPath,
      snapshotSha256Hex: snapshotSha256Hex,
      createdAt: createdAt,
      downloadUrl: downloadUrl ?? this.downloadUrl,
    );
  }
}
