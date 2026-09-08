import 'package:flutter/material.dart';

import 'app_colors.dart';

/// نظام الخطوط والطباعة المعياري لتطبيق «مُثبَت | MUTHBAT»
class AppTypography {
  AppTypography._();

  // الخط العربي الأساسي المعتمد للعلامة والواجهات
  static String get arabicFontFamily => 'Tajawal';
  // الخط الإنجليزي والأرقام
  static String get latinFontFamily => 'Tajawal';

  /// العناوين الكبرى والشاشات الرئيسية
  static TextStyle displayLarge({Color color = AppColors.textPrimary}) =>
      TextStyle(
        fontFamily: 'Tajawal',
        fontSize: 32,
        fontWeight: FontWeight.w800,
        color: color,
        height: 1.25,
      );

  static TextStyle displayMedium({Color color = AppColors.textPrimary}) =>
      TextStyle(
        fontFamily: 'Tajawal',
        fontSize: 26,
        fontWeight: FontWeight.w700,
        color: color,
        height: 1.3,
      );

  static TextStyle get heading1 => displayLarge();
  static TextStyle get heading2 => displayMedium();
  static TextStyle get heading3 => titleLarge();
  static TextStyle get titleLargeStyle => titleLarge();
  static TextStyle get titleMediumStyle => titleMedium();
  static TextStyle get bodyLargeStyle => bodyLarge();
  static TextStyle get bodyMediumStyle => bodyMedium();
  static TextStyle get bodySmallStyle => bodySmall();
  static TextStyle get captionStyle => caption();

  /// عناوين البطاقات والأقسام
  static TextStyle titleLarge({Color color = AppColors.textPrimary}) =>
      TextStyle(
        fontFamily: 'Tajawal',
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: color,
        height: 1.35,
      );

  static TextStyle titleMedium({Color color = AppColors.textPrimary}) =>
      TextStyle(
        fontFamily: 'Tajawal',
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: color,
        height: 1.4,
      );

  static TextStyle titleSmall({Color color = AppColors.textSecondary}) =>
      TextStyle(
        fontFamily: 'Tajawal',
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: color,
        height: 1.4,
      );

  /// نصوص المحتوى وجسم الواجهة (Body)
  static TextStyle bodyLarge({Color color = AppColors.textPrimary}) =>
      TextStyle(
        fontFamily: 'Tajawal',
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: color,
        height: 1.5,
      );

  static TextStyle bodyMedium({Color color = AppColors.textSecondary}) =>
      TextStyle(
        fontFamily: 'Tajawal',
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: color,
        height: 1.5,
      );

  static TextStyle bodySmall({Color color = AppColors.textMuted}) => TextStyle(
    fontFamily: 'Tajawal',
    fontSize: 11.5,
    fontWeight: FontWeight.w400,
    color: color,
    height: 1.4,
  );

  static TextStyle caption({Color color = AppColors.textSecondary}) =>
      bodySmall(color: color);

  /// الأرقام والمبالغ المالية (Financial Currency Typography)
  static TextStyle financialAmount({
    Color color = AppColors.textPrimary,
    double fontSize = 24,
    FontWeight fontWeight = FontWeight.w800,
  }) => TextStyle(
    fontFamily: 'Tajawal',
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    letterSpacing: -0.5,
  );

  /// الكلمات الإنجليزية والوسوم (English Wordmark)
  static TextStyle englishWordmark({
    Color color = AppColors.secondaryLight,
    double fontSize = 12,
    double letterSpacing = 4.0,
  }) => TextStyle(
    fontFamily: 'Tajawal',
    fontSize: fontSize,
    fontWeight: FontWeight.w800,
    letterSpacing: letterSpacing,
    color: color,
  );

  /// الشعار التسويقي (Tagline)
  static TextStyle tagline({Color color = AppColors.textSecondary}) =>
      TextStyle(
        fontFamily: 'Tajawal',
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
        color: color,
      );
}
