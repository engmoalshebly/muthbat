import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';

/// ويدجت اختيار وإرفاق المستندات وصور الفواتير
class AttachmentPickerWidget extends StatefulWidget {
  final ValueChanged<File?> onFileSelected;
  final String label;

  const AttachmentPickerWidget({
    super.key,
    required this.onFileSelected,
    this.label = 'إرفاق صورة الفاتورة / السند (اختياري)',
  });

  @override
  State<AttachmentPickerWidget> createState() => _AttachmentPickerWidgetState();
}

class _AttachmentPickerWidgetState extends State<AttachmentPickerWidget> {
  final ImagePicker _picker = ImagePicker();
  File? _pickedFile;

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 80,
      );

      if (picked != null) {
        final file = File(picked.path);
        setState(() => _pickedFile = file);
        widget.onFileSelected(file);
      }
    } catch (e) {
      debugPrint('[AttachmentPickerWidget] Pick error: $e');
    }
  }

  void _showPickerOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.borderMedium,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'اختيار صورة المرفق / الفاتورة',
              style: AppTypography.titleMedium(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      Navigator.pop(ctx);
                      _pickImage(ImageSource.camera);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      decoration: BoxDecoration(
                        color: AppColors.primaryLight.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.primaryLight.withValues(alpha: 0.3)),
                      ),
                      child: const Column(
                        children: [
                          Icon(Icons.camera_alt_rounded, size: 32, color: AppColors.primary),
                          SizedBox(height: 8),
                          Text('التقاط بالكاميرا', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.primary)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      Navigator.pop(ctx);
                      _pickImage(ImageSource.gallery);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      decoration: BoxDecoration(
                        color: AppColors.secondary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
                      ),
                      child: const Column(
                        children: [
                          Icon(Icons.photo_library_rounded, size: 32, color: AppColors.secondary),
                          SizedBox(height: 8),
                          Text('اختيار من المعرض', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.secondary)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _removeFile() {
    setState(() => _pickedFile = null);
    widget.onFileSelected(null);
  }

  @override
  Widget build(BuildContext context) {
    if (_pickedFile != null) {
      final sizeKb = (_pickedFile!.lengthSync() / 1024).toStringAsFixed(1);

      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.success.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                _pickedFile!,
                width: 54,
                height: 54,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.check_circle_rounded, size: 14, color: AppColors.success),
                      SizedBox(width: 4),
                      Text(
                        'تم اختيار المرفق بنجاح',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppColors.success),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'الحجم: $sizeKb ك.ب',
                    style: AppTypography.caption(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'حذف المرفق',
              icon: const Icon(Icons.delete_outline_rounded, color: AppColors.debtRed, size: 20),
              onPressed: _removeFile,
            ),
          ],
        ),
      );
    }

    return InkWell(
      onTap: _showPickerOptions,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Row(
          children: [
            const Icon(Icons.attach_file_rounded, color: AppColors.textSecondary, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.label,
                style: AppTypography.bodySmall(color: AppColors.textSecondary),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'إضافة',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
