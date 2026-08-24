class DocumentModel {
  final String id;
  final String? entityId;
  final String objectPath;
  final String originalFilename;
  final String mimeType;
  final int sizeBytes;
  final String? sha256Hex;
  final String? uploadedAt;
  final String? downloadUrl;

  const DocumentModel({
    required this.id,
    this.entityId,
    required this.objectPath,
    required this.originalFilename,
    required this.mimeType,
    required this.sizeBytes,
    this.sha256Hex,
    this.uploadedAt,
    this.downloadUrl,
  });

  factory DocumentModel.fromMap(Map<String, dynamic> map, {String? downloadUrl}) {
    return DocumentModel(
      id: map['id'] as String,
      entityId: map['entity_id'] as String?,
      objectPath: map['object_path'] as String? ?? '',
      originalFilename: map['original_filename'] as String? ?? 'مستند',
      mimeType: map['mime_type'] as String? ?? 'application/octet-stream',
      sizeBytes: (map['size_bytes'] as num?)?.toInt() ?? 0,
      sha256Hex: map['sha256_hex'] as String?,
      uploadedAt: map['created_at'] as String?,
      downloadUrl: downloadUrl ?? map['downloadUrl'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'entity_id': entityId,
      'object_path': objectPath,
      'original_filename': originalFilename,
      'mime_type': mimeType,
      'size_bytes': sizeBytes,
      'sha256_hex': sha256Hex,
      'created_at': uploadedAt,
    };
  }

  bool get isImage => mimeType.startsWith('image/');
  bool get isPdf => mimeType == 'application/pdf';
}
