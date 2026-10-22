import 'package:flutter/material.dart';

import '../../../../core/config/env.dart';

/// Describes the temporary registration policy without claiming phone ownership.
class PhoneRegistrationNotice extends StatelessWidget {
  const PhoneRegistrationNotice({super.key, this.registration = false});

  final bool registration;

  @override
  Widget build(BuildContext context) {
    if (EnvConfig.phoneVerificationEnabled) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 20, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              registration
                  ? 'استخدم رقمك الشخصي. لن نرسل رمز تحقق حاليًا، وستبقى جلستك محفوظة بأمان. احفظ كلمة المرور في مدير كلمات المرور؛ استعادة الحساب غير متاحة حاليًا.'
                  : 'التحقق من ملكية الهاتف مؤجل. لن تُربط السجلات السابقة بحسابك اعتمادًا على الرقم وحده.',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
