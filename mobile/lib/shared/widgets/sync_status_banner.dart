import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_icons.dart';
import '../../core/sync/sync_engine.dart';

/// شريط حالة المزامنة الدائم — يعرض للمستخدم بوضوح:
/// «متزامن ✓» / «N عملية معلقة» / «لا يوجد اتصال» / خطأ المزامنة الفعلي.
/// يختفي تماماً عندما لا جديد يستحق العرض (idle بلا معلقات).
class SyncStatusBanner extends StatelessWidget {
  /// يُستدعى عند الضغط على الشريط وهناك عمليات معلقة (مثلاً لفتح شاشة المراجعة).
  final VoidCallback? onReviewTap;

  const SyncStatusBanner({super.key, this.onReviewTap});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncProgress>(
      stream: SyncEngine.instance.progressStream,
      builder: (context, snapshot) {
        final progress = snapshot.data;

        // لا شيء يستحق العرض قبل أول حدث مزامنة
        if (progress == null) return const SizedBox.shrink();

        final pending = progress.pendingCount;

        Color bgColor;
        Color fgColor;
        IconData icon;
        String text;
        VoidCallback? onTap;

        switch (progress.state) {
          case SyncState.syncing:
            bgColor = AppColors.infoLight;
            fgColor = AppColors.info;
            icon = Icons.sync_rounded;
            text = progress.lastMessage ?? 'جاري المزامنة مع الخادم...';
            break;
          case SyncState.offline:
            bgColor = AppColors.warningLight;
            fgColor = AppColors.warning;
            icon = Icons.cloud_off_rounded;
            text = progress.lastMessage ?? 'لا يوجد اتصال بالإنترنت — البيانات الجديدة غير موثقة بعد';
            break;
          case SyncState.error:
            bgColor = AppColors.errorLight;
            fgColor = AppColors.error;
            icon = Icons.error_outline_rounded;
            text = progress.lastMessage ?? 'تعذرت المزامنة — حاول مرة أخرى';
            onTap = () => SyncEngine.instance.triggerSync();
            break;
          case SyncState.synced:
            if (pending > 0) {
              bgColor = AppColors.warningLight;
              fgColor = AppColors.warning;
              icon = Icons.hourglass_top_rounded;
              text = '$pending عملية بانتظار المزامنة — الأرصدة المتأثرة غير موثقة بعد';
              onTap = onReviewTap ?? () => SyncEngine.instance.triggerSync();
            } else {
              bgColor = AppColors.successLight;
              fgColor = AppColors.success;
              icon = Icons.cloud_done_rounded;
              text = 'متزامن ✓ كل البيانات موثقة';
            }
            break;
          case SyncState.idle:
          default:
            if (pending > 0) {
              bgColor = AppColors.warningLight;
              fgColor = AppColors.warning;
              icon = Icons.hourglass_top_rounded;
              text = '$pending عملية بانتظار المزامنة — الأرصدة المتأثرة غير موثقة بعد';
              onTap = onReviewTap ?? () => SyncEngine.instance.triggerSync();
            } else {
              return const SizedBox.shrink();
            }
            break;
        }

        return Material(
          color: bgColor,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              child: Row(
                children: [
                  if (progress.state == SyncState.syncing)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: fgColor),
                    )
                  else
                    Icon(icon, size: 15, color: fgColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fgColor),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (onTap != null)
                    Icon(AppIcons.chevronStart, size: 16, color: fgColor),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
