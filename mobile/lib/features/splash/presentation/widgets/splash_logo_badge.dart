import 'package:flutter/material.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../core/constants/asset_paths.dart';

/// الشارة العائمة والأيقونة المركزية في شاشة البداية
class SplashLogoBadge extends StatelessWidget {
  final double size;

  const SplashLogoBadge({super.key, this.size = 120.0});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryDark.withValues(alpha: 0.5),
            blurRadius: 35,
            offset: const Offset(0, 14),
          ),
          BoxShadow(
            color: AppColors.accentGold.withValues(alpha: 0.25),
            blurRadius: 24,
            spreadRadius: 2,
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Center(
        child: Image.asset(
          AssetPaths.iconPng,
          width: size * 0.75,
          height: size * 0.75,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}
