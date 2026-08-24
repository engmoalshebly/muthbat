import 'package:flutter/material.dart';
import 'app_colors.dart';

/// تأثيرات الزينة، الظلال، وحواف البطاقات
class AppDecorations {
  AppDecorations._();

  static const double radiusSmall = 8.0;
  static const double radiusMedium = 14.0;
  static const double radiusLarge = 20.0;
  static const double radiusPill = 999.0;

  static final BorderRadius roundedSmall = BorderRadius.circular(radiusSmall);
  static final BorderRadius roundedMedium = BorderRadius.circular(radiusMedium);
  static final BorderRadius roundedLarge = BorderRadius.circular(radiusLarge);
  static final BorderRadius roundedPill = BorderRadius.circular(radiusPill);

  // ظلال ناعمة مالية (FinTech Subtle Shadows)
  static final List<BoxShadow> cardShadow = [
    BoxShadow(
      color: const Color(0xFF123B46).withValues(alpha: 0.06),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
    BoxShadow(
      color: const Color(0xFF123B46).withValues(alpha: 0.02),
      blurRadius: 4,
      offset: const Offset(0, 1),
    ),
  ];

  static final List<BoxShadow> elevatedShadow = [
    BoxShadow(
      color: const Color(0xFF123B46).withValues(alpha: 0.12),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
  ];

  static final List<BoxShadow> goldGlow = [
    BoxShadow(
      color: AppColors.accentGold.withValues(alpha: 0.35),
      blurRadius: 20,
      offset: const Offset(0, 4),
    ),
  ];

  static final List<BoxShadow> tealGlow = [
    BoxShadow(
      color: AppColors.secondary.withValues(alpha: 0.3),
      blurRadius: 20,
      offset: const Offset(0, 4),
    ),
  ];
}
