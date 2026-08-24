import 'package:flutter/material.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';

enum UserAccountType {
  merchant,
  customer,
}

/// محدد نوع الحساب (صاحب محل أو عميل)
class UserTypeSelector extends StatelessWidget {
  final UserAccountType selectedType;
  final ValueChanged<UserAccountType> onTypeChanged;

  const UserTypeSelector({
    super.key,
    required this.selectedType,
    required this.onTypeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _buildCard(
            type: UserAccountType.merchant,
            title: 'صاحب محل',
            subtitle: 'لإدارة الديون والتحصيل',
            icon: Icons.storefront_outlined,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildCard(
            type: UserAccountType.customer,
            title: 'عميل / فرد',
            subtitle: 'لمتابعة ديوني وتأكيدها',
            icon: Icons.person_outline_rounded,
          ),
        ),
      ],
    );
  }

  Widget _buildCard({
    required UserAccountType type,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final isSelected = selectedType == type;

    return InkWell(
      onTap: () => onTypeChanged(type),
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primaryContainer.withValues(alpha: 0.6) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? AppColors.secondary : AppColors.borderLight,
            width: isSelected ? 2.0 : 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: isSelected
                  ? AppColors.secondary.withValues(alpha: 0.12)
                  : AppColors.primary.withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.secondary : AppColors.backgroundLight,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 24,
                color: isSelected ? Colors.white : AppColors.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: AppTypography.titleSmall(
                color: isSelected ? AppColors.primary : AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: AppTypography.bodySmall(
                color: isSelected ? AppColors.secondaryDark : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
