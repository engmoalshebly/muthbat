import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router/app_routes.dart';
import 'controllers/auth_controller.dart';

Future<void> confirmAccountSignOut(BuildContext context, WidgetRef ref) async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final confirm = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('تسجيل الخروج من هذا الجهاز'),
      content: const Text(
        'ستبقى بيانات هذا الحساب والعمليات غير المزامنة محفوظة على الجهاز. '
        'تستأنف المزامنة بعد الدخول إلى الحساب نفسه بجلسة صالحة؛ وقد تحتاج العمليات المرفوضة إلى مراجعة. '
        'لن تُحذف بيانات الجهاز ولن تُسجّل الأجهزة الأخرى خروجًا.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('تسجيل الخروج'),
        ),
      ],
    ),
  );
  if (confirm != true || !context.mounted) return;
  final controller = ref.read(authControllerProvider.notifier);
  final result = await controller.signOut();
  // The guard can dispose the original account screen during sign-out.
  if (!navigator.mounted) return;
  if (result.signedOut) {
    navigator.pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
    if (messenger.mounted) {
      final count = result.preservedPendingCount;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            count != null && count > 0
                ? 'تم الخروج. احتُفظ بـ $count عملية لهذا الحساب على الجهاز.'
                : 'تم الخروج من هذا الجهاز. بيانات الحساب المحلية محفوظة.',
          ),
        ),
      );
    }
  } else if (messenger.mounted) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('تعذر إكمال الخروج. بياناتك محفوظة؛ حاول مجددًا.'),
      ),
    );
  }
}
