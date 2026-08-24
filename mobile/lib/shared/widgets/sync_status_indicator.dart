import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../../core/sync/sync_engine.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_typography.dart';

import '../../../app/theme/app_icons.dart';

/// مؤشر وشريط حالة المزامنة اللحظي (Sync Status Indicator)
/// يعرض حالة الشبكة والأوامر المعلقة في طابور الأوفلاين للتاجر بشكل سلس وأنيق.
class SyncStatusIndicator extends StatelessWidget {
  final bool compact;

  const SyncStatusIndicator({
    super.key,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncProgress>(
      stream: SyncEngine.instance.progressStream,
      builder: (context, snapshot) {
        final progress = snapshot.data ??
            const SyncProgress(
              state: SyncState.synced,
              pendingCount: 0,
            );

        if (compact) {
          return _buildCompactBadge(context, progress);
        }

        return _buildFullBanner(context, progress);
      },
    );
  }

  Widget _buildCompactBadge(BuildContext context, SyncProgress progress) {
    Color badgeColor;
    IconData icon;
    String label;

    switch (progress.state) {
      case SyncState.syncing:
        badgeColor = AppColors.secondary;
        icon = AppIcons.sync;
        label = 'مزامنة...';
        break;
      case SyncState.offline:
        badgeColor = Colors.orange;
        icon = AppIcons.offline;
        label = progress.pendingCount > 0 ? '${progress.pendingCount} معلق' : 'أوفلاين';
        break;
      case SyncState.error:
        badgeColor = AppColors.error;
        icon = AppIcons.warning;
        label = 'تنبيه مزامنة';
        break;
      case SyncState.synced:
      case SyncState.idle:
      default:
        if (progress.pendingCount > 0) {
          badgeColor = Colors.orange;
          icon = AppIcons.pendingUpload;
          label = '${progress.pendingCount} معلق';
        } else {
          badgeColor = AppColors.success;
          icon = AppIcons.synced;
          label = 'متزامن';
        }
    }

    return InkWell(
      onTap: () => _handleTap(context, progress),
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: badgeColor.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: badgeColor.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (progress.state == SyncState.syncing)
              RotationTransition(
                turns: const AlwaysStoppedAnimation(0.5),
                child: Icon(icon, size: 14, color: badgeColor)
                    .animate(onPlay: (controller) => controller.repeat())
                    .rotate(duration: 1.seconds),
              )
            else
              Icon(icon, size: 14, color: badgeColor),
            const SizedBox(width: 5),
            Text(
              label,
              style: AppTypography.bodySmall(color: badgeColor).copyWith(
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFullBanner(BuildContext context, SyncProgress progress) {
    // إخفاء الشريط التلقائي إذا كانت كل البيانات متزامنة تماماً
    if (progress.state == SyncState.synced && progress.pendingCount == 0 && progress.deadLetterCount == 0) {
      return const SizedBox.shrink();
    }

    Color bgColor;
    Color textColor;
    IconData icon;
    String message;

    switch (progress.state) {
      case SyncState.syncing:
        bgColor = AppColors.secondary.withValues(alpha: 0.12);
        textColor = AppColors.secondary;
        icon = AppIcons.sync;
        message = 'جاري مزامنة ${progress.pendingCount} عملية مع السيرفر...';
        break;
      case SyncState.offline:
        bgColor = Colors.orange.withValues(alpha: 0.12);
        textColor = Colors.orange.shade800;
        icon = AppIcons.offline;
        message = progress.pendingCount > 0
            ? 'أنت تعمل محلياً (${progress.pendingCount} عملية بانتظار عودة الشبكة)'
            : 'أنت في وضع عدم الاتصال (البيانات محفوظة بأمان محلياً)';
        break;
      case SyncState.error:
        bgColor = AppColors.error.withValues(alpha: 0.12);
        textColor = AppColors.error;
        icon = AppIcons.dispute;
        message = progress.deadLetterCount > 0
            ? '${progress.deadLetterCount} عملية تتطلب مراجعة. اضغط للتفاصيل.'
            : 'تعذر إكمال المزامنة. اضغط لإعادة المحاولة.';
        break;
      default:
        if (progress.pendingCount > 0) {
          bgColor = Colors.orange.withValues(alpha: 0.12);
          textColor = Colors.orange.shade800;
          icon = AppIcons.pendingUpload;
          message = '${progress.pendingCount} عملية محفوظة محلياً بانتظار المزامنة';
        } else {
          return const SizedBox.shrink();
        }
    }

    return InkWell(
      onTap: () => _handleTap(context, progress),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: bgColor,
        child: Row(
          children: [
            if (progress.state == SyncState.syncing)
              Icon(icon, size: 18, color: textColor)
                  .animate(onPlay: (c) => c.repeat())
                  .rotate(duration: 1.seconds)
            else
              Icon(icon, size: 18, color: textColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: AppTypography.bodySmall(color: textColor).copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
            Icon(AppIcons.chevronEnd, size: 18, color: textColor),
          ],
        ),
      ),
    );
  }

  void _handleTap(BuildContext context, SyncProgress progress) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _SyncDetailsSheet(progress: progress),
    );
  }
}

class _SyncDetailsSheet extends StatelessWidget {
  final SyncProgress progress;

  const _SyncDetailsSheet({required this.progress});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AppIconBox.primary(
                icon: AppIcons.sync,
                size: 24,
                padding: 12,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('حالة مزامنة الدفتر', style: AppTypography.heading3),
                    const SizedBox(height: 2),
                    Text(
                      progress.lastSyncAt != null
                          ? 'آخر مزامنة ناجحة: ${_formatTime(progress.lastSyncAt!)}'
                          : 'المزامنة تعمل تلقائياً فور توفر الشبكة',
                      style: AppTypography.bodySmall(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.backgroundLight,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              children: [
                _buildRow('العمليات المعلقة في الطابور', '${progress.pendingCount}', AppColors.textPrimary),
                const Divider(height: 20),
                _buildRow('العمليات قيد الإرسال', progress.state == SyncState.syncing ? 'نشطة' : 'متوقفة', AppColors.primary),
                if (progress.deadLetterCount > 0) ...[
                  const Divider(height: 20),
                  _buildRow('عمليات بحاجة لمراجعة', '${progress.deadLetterCount}', AppColors.error),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              SyncEngine.instance.triggerSync();
            },
            icon: const Icon(AppIcons.sync),
            label: const Text('مزامنة الآن يدويّاً'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _buildRow(String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: AppTypography.bodySmall()),
        Text(value, style: AppTypography.bodyMedium(color: valueColor).copyWith(fontWeight: FontWeight.bold)),
      ],
    );
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final period = dt.hour >= 12 ? 'م' : 'ص';
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute $period';
  }
}
