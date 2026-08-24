import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';

enum ButtonVariant {
  primary,
  secondary,
  gold,
  outline,
  text,
}

/// زر تفاعلي فاخر متعدد الأنماط لمنظومة «مُثبَت | MUTHBAT»
class CustomButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final ButtonVariant variant;
  final bool isLoading;
  final IconData? icon;
  final double? width;
  final double height;
  final BorderRadius? borderRadius;

  const CustomButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.variant = ButtonVariant.primary,
    this.isLoading = false,
    this.icon,
    this.width,
    this.height = 54.0,
    this.borderRadius,
  });

  const CustomButton.gold({
    super.key,
    required this.text,
    required this.onPressed,
    this.isLoading = false,
    this.icon,
    this.width,
    this.height = 54.0,
    this.borderRadius,
  }) : variant = ButtonVariant.gold;

  const CustomButton.secondary({
    super.key,
    required this.text,
    required this.onPressed,
    this.isLoading = false,
    this.icon,
    this.width,
    this.height = 54.0,
    this.borderRadius,
  }) : variant = ButtonVariant.secondary;

  const CustomButton.outline({
    super.key,
    required this.text,
    required this.onPressed,
    this.isLoading = false,
    this.icon,
    this.width,
    this.height = 54.0,
    this.borderRadius,
  }) : variant = ButtonVariant.outline;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(14.0);

    if (variant == ButtonVariant.text) {
      return TextButton(
        onPressed: isLoading ? null : onPressed,
        style: TextButton.styleFrom(
          foregroundColor: AppColors.secondary,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
        child: Text(
          text,
          style: AppTypography.titleSmall(color: AppColors.secondary),
        ),
      );
    }

    if (variant == ButtonVariant.outline) {
      return SizedBox(
        width: width ?? double.infinity,
        height: height,
        child: OutlinedButton(
          onPressed: isLoading ? null : onPressed,
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppColors.borderLight, width: 1.5),
            shape: RoundedRectangleBorder(borderRadius: radius),
            foregroundColor: AppColors.textPrimary,
          ),
          child: _buildContent(AppColors.textPrimary),
        ),
      );
    }

    // الأزرار الملونة بالتدرجات (Primary, Secondary, Gold)
    Gradient gradient;
    Color textColor;
    List<BoxShadow> shadows;

    switch (variant) {
      case ButtonVariant.gold:
        gradient = AppColors.goldGradient;
        textColor = const Color(0xFF4A3408);
        shadows = [
          BoxShadow(
            color: AppColors.accentGold.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ];
        break;
      case ButtonVariant.secondary:
        gradient = AppColors.tealGradient;
        textColor = Colors.white;
        shadows = [
          BoxShadow(
            color: AppColors.secondary.withValues(alpha: 0.28),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ];
        break;
      case ButtonVariant.primary:
      default:
        gradient = AppColors.brandGradient;
        textColor = Colors.white;
        shadows = [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.24),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ];
        break;
    }

    final bool isDisabled = onPressed == null || isLoading;

    return Container(
      width: width ?? double.infinity,
      height: height,
      decoration: BoxDecoration(
        gradient: isDisabled ? null : gradient,
        color: isDisabled ? AppColors.borderLight : null,
        borderRadius: radius,
        boxShadow: isDisabled ? null : shadows,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isDisabled ? null : onPressed,
          borderRadius: radius,
          splashColor: Colors.white.withValues(alpha: 0.15),
          highlightColor: Colors.white.withValues(alpha: 0.08),
          child: Center(
            child: _buildContent(isDisabled ? AppColors.textMuted : textColor),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(Color color) {
    if (isLoading) {
      return SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2.4,
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
        ],
        Text(
          text,
          style: AppTypography.titleSmall(color: color).copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
