class DisputeMessageModel {
  final String id;
  final String disputeId;
  final String senderUserId;
  final String message;
  final String createdAt;
  final String? senderName;

  const DisputeMessageModel({
    required this.id,
    required this.disputeId,
    required this.senderUserId,
    required this.message,
    required this.createdAt,
    this.senderName,
  });

  factory DisputeMessageModel.fromMap(Map<String, dynamic> map, {String? currentUserId}) {
    final senderId = map['sender_user_id'] as String;
    return DisputeMessageModel(
      id: map['id'] as String,
      disputeId: map['dispute_id'] as String,
      senderUserId: senderId,
      message: map['message'] as String,
      createdAt: map['created_at'] as String,
      // تسمية المرسل تُشتق في العميل (لا تضمين profiles — خطة 06 خطوة 3.4)
      senderName: map['sender_name'] as String? ??
          (currentUserId != null && senderId == currentUserId ? 'أنت' : null),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'dispute_id': disputeId,
      'sender_user_id': senderUserId,
      'message': message,
      'created_at': createdAt,
    };
  }
}
