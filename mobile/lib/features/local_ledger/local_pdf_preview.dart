import 'dart:typed_data';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import '../../app/theme/app_colors.dart';

class LocalPdfPreview extends StatefulWidget {
  const LocalPdfPreview({
    super.key,
    required this.bytes,
    required this.filename,
  });
  final Uint8List bytes;
  final String filename;
  @override
  State<LocalPdfPreview> createState() => _LocalPdfPreviewState();
}

class _LocalPdfPreviewState extends State<LocalPdfPreview> {
  bool busy = false;

  Future<void> perform(bool save) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      if (save) {
        final path = await FileSaver.instance.saveAs(
          name: widget.filename,
          bytes: widget.bytes,
          fileExtension: 'pdf',
          mimeType: MimeType.pdf,
        );
        if (!mounted || path == null || path.isEmpty) return;
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(
              Icons.check_circle_rounded,
              color: AppColors.success,
              size: 36,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Text('تم الحفظ بنجاح', textAlign: TextAlign.center),
            content: const Text(
              'تقريرك جاهز. يمكنك الرجوع إليه من تطبيق الملفات أو مشاركته في أي وقت.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, height: 1.6),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('حسنًا'),
              ),
            ],
          ),
        );
      } else {
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(
          ShareParams(
            files: [
              XFile.fromData(
                widget.bytes,
                mimeType: 'application/pdf',
                name: '${widget.filename}.pdf',
              ),
            ],
            fileNameOverrides: ['${widget.filename}.pdf'],
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر إكمال العملية. حاول مرة أخرى.')),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.backgroundLight,
    appBar: AppBar(title: const Text('عرض التقرير')),
    body: PdfPreview(
      build: (_) async => widget.bytes,
      allowPrinting: false,
      allowSharing: false,
      canChangePageFormat: false,
      canChangeOrientation: false,
      canDebug: false,
      useActions: false,
    ),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : () => perform(true),
                icon: const Icon(Icons.download_rounded, size: 19),
                label: const Text('حفظ باسم'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : () => perform(false),
                icon: const Icon(Icons.share_outlined, size: 19),
                label: const Text('مشاركة'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
