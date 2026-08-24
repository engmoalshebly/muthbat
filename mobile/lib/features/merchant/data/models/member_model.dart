class MemberModel {
  final String id;
  final String businessId;
  final String userId;
  final String role; // 'owner', 'admin', 'accountant', 'collector'
  final String status; // 'active', 'suspended', 'removed'
  final String? displayName;
  final String? phone;
  final String? createdAt;

  const MemberModel({
    required this.id,
    required this.businessId,
    required this.userId,
    required this.role,
    this.status = 'active',
    this.displayName,
    this.phone,
    this.createdAt,
  });

  factory MemberModel.fromMap(Map<String, dynamic> map) {
    final profile = map['profiles'] as Map<String, dynamic>?;

    return MemberModel(
      id: map['id'] as String,
      businessId: map['business_id'] as String,
      userId: map['user_id'] as String,
      role: map['role'] as String,
      status: map['status'] as String? ?? 'active',
      displayName: profile != null ? profile['display_name'] as String? : map['display_name'] as String?,
      phone: profile != null ? profile['phone'] as String? : map['phone'] as String?,
      createdAt: map['created_at'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'business_id': businessId,
      'user_id': userId,
      'role': role,
      'status': status,
      'created_at': createdAt,
    };
  }

  String get roleLocalized {
    switch (role) {
      case 'owner':
        return 'المالك';
      case 'admin':
        return 'مدير النظام';
      case 'accountant':
        return 'محاسب مالي';
      case 'collector':
        return 'محصّل ميداني';
      default:
        return role;
    }
  }

  String get roleDescription {
    switch (role) {
      case 'owner':
        return 'صلاحيات كاملة لإدارة المؤسسة والمعاملات وفريق العمل';
      case 'admin':
        return 'صلاحيات إدارية للقيود والتقارير ودعوة الموظفين';
      case 'accountant':
        return 'تسجيل القيود وتوليد كشوف الحسابات والتسويات المالية';
      case 'collector':
        return 'تسجيل تحصيل الدفعات ومتابعة حسابات العملاء';
      default:
        return '';
    }
  }
}

class MemberInviteModel {
  final String id;
  final String businessId;
  final String targetUserId;
  final String role;
  final String status; // 'pending', 'accepted', 'rejected', 'expired', 'cancelled'
  final String invitedByUserId;
  final String expiresAt;
  final String createdAt;
  final String? targetUserName;

  const MemberInviteModel({
    required this.id,
    required this.businessId,
    required this.targetUserId,
    required this.role,
    this.status = 'pending',
    required this.invitedByUserId,
    required this.expiresAt,
    required this.createdAt,
    this.targetUserName,
  });

  factory MemberInviteModel.fromMap(Map<String, dynamic> map) {
    return MemberInviteModel(
      id: map['id'] as String,
      businessId: map['business_id'] as String,
      targetUserId: map['target_user_id'] as String,
      role: map['role'] as String,
      status: map['status'] as String? ?? 'pending',
      invitedByUserId: map['invited_by_user_id'] as String,
      expiresAt: map['expires_at'] as String,
      createdAt: map['created_at'] as String,
      targetUserName: map['target_user_name'] as String?,
    );
  }

  String get roleLocalized {
    switch (role) {
      case 'admin':
        return 'مدير النظام';
      case 'accountant':
        return 'محاسب مالي';
      case 'collector':
        return 'محصّل ميداني';
      default:
        return role;
    }
  }

  String get statusLocalized {
    switch (status) {
      case 'pending':
        return 'بانتظار القبول';
      case 'accepted':
        return 'مقبولة';
      case 'rejected':
        return 'مرفوضة';
      case 'expired':
        return 'منتهية الصلاحية';
      case 'cancelled':
        return 'ملغاة';
      default:
        return status;
    }
  }
}
