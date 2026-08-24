import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/brand_logo.dart';

/// ترويسة شاشات المصادقة والحسابات
class AuthHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool showLogo;

  const AuthHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.showLogo = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (showLogo) ...[
          const BrandLogo.primary(width: 210)
              .animate()
              .scale(begin: const Offset(0.85, 0.85), end: const Offset(1, 1), duration: 500.ms, curve: Curves.easeOutBack)
              .fadeIn(duration: 400.ms),
          const SizedBox(height: 16),
        ],
        Text(
          title,
          textAlign: TextAlign.center,
          style: AppTypography.displayMedium(color: AppColors.primary).copyWith(
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ).animate().fadeIn(delay: 150.ms, duration: 400.ms).slideY(begin: 0.15, end: 0),
        const SizedBox(height: 6),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: AppTypography.bodyMedium(color: AppColors.textSecondary).copyWith(
            height: 1.4,
            fontSize: 13,
          ),
        ).animate().fadeIn(delay: 250.ms, duration: 400.ms).slideY(begin: 0.15, end: 0),
      ],
    );
  }
}
