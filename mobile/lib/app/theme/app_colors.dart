import 'package:flutter/material.dart';

/// نظام ألوان هوية «مُثبَت | MUTHBAT» المعتمد
class AppColors {
  AppColors._();

  // --- الألوان الأساسية (Primary Brand Palette) ---
  /// Deep Petrol Navy (#123B46) - لون الثقة والرسوخ المالي
  static const Color primary = Color(0xFF123B46);
  static const Color primaryLight = Color(0xFF1B5362);
  static const Color primaryDark = Color(0xFF0B252D);
  static const Color primaryContainer = Color(0xFFE2F0F3);

  // --- اللون الثانوي (Secondary Brand Palette) ---
  /// Teal (#138577) - لون التقنية والحداثة والنشاط المالي
  static const Color secondary = Color(0xFF138577);
  static const Color secondaryLight = Color(0xFF1FB2A0);
  static const Color secondaryDark = Color(0xFF0D5E54);
  static const Color secondaryContainer = Color(0xFFD6F3EE);

  // --- اللون المميز (Accent Color) ---
  /// Warm Gold (#D9A441) - رمز التوثيق وعلامة الاعتماد
  static const Color accentGold = Color(0xFFD9A441);
  static const Color accentGoldLight = Color(0xFFF2C76D);
  static const Color accentGoldDark = Color(0xFFA67822);
  static const Color accentGoldContainer = Color(0xFFFBF2DC);

  // --- الخلفيات والأسطح (Backgrounds & Surfaces) ---
  static const Color backgroundLight = Color(0xFFF7F9F7);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color surfaceElevated = Color(0xFFFFFFFF);
  static const Color navBackground = Color(0xFFFFFFFF);
  static const Color navInactive = Color(0xFF829196);

  static const Color backgroundDark = Color(0xFF0A1E24);
  static const Color surfaceDark = Color(0xFF102A32);
  static const Color surfaceDarkElevated = Color(0xFF173842);

  // --- النصوص (Typography Colors) ---
  static const Color textPrimary = Color(0xFF172529);
  static const Color textSecondary = Color(0xFF5E7175);
  static const Color textMuted = Color(0xFF8E9FA2);
  static const Color textWhite = Color(0xFFFFFFFF);
  static const Color textWhiteSecondary = Color(0xFFD4E1E3);

  // --- الحدود والفواصل (Borders & Dividers) ---
  static const Color borderLight = Color(0xFFE1E7E5);
  static const Color borderSubtle = Color(0xFFECEFEF);
  static const Color borderDark = Color(0xFF224953);

  // --- الحالات التشغيلية والمالية (Semantic & Financial Statuses) ---
  /// السداد، التحصيل، الدفعات، الحركات المؤكدة
  static const Color success = Color(0xFF2E8B68);
  static const Color successLight = Color(0xFFE5F6EE);
  static const Color paymentGreen = Color(0xFF2E8B68);

  /// بانتظار التأكيد، المراجعة، التنبيهات
  static const Color warning = Color(0xFFD98A28);
  static const Color warningLight = Color(0xFFFDF2E2);

  /// الديون المتأخرة، الاعتراضات المفتوحة، الأخطاء
  static const Color error = Color(0xFFC94F4F);
  static const Color errorLight = Color(0xFFFBECEC);
  static const Color debtRed = Color(0xFFC94F4F);

  /// حدود متوسطة
  static const Color borderMedium = Color(0xFFC5D1CF);

  /// معلومات عامة، إشعارات الربط
  static const Color info = Color(0xFF2176AE);
  static const Color infoLight = Color(0xFFEAF3F9);

  // --- ألوان شارات التصنيف (Category Badges) ---
  static const Color badgeGoodsBg = Color(0xFFF0F4F5);
  static const Color badgeGoodsText = Color(0xFF2C4A50);
  static const Color badgeCashBg = Color(0xFFE8F5EE);
  static const Color badgeCashText = Color(0xFF1B6B4A);
  static const Color badgeServiceBg = Color(0xFFFBF2DC);
  static const Color badgeServiceText = Color(0xFF8B6B1F);
  static const Color badgeTransferBg = Color(0xFFEAF0F3);
  static const Color badgeTransferText = Color(0xFF1B4A5A);
  static const Color badgeRefBg = Color(0xFFE2F0F3);
  static const Color badgeRefText = Color(0xFF123B46);

  // --- تدرجات اللونية الفاخرة (Gradients) ---
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
    colors: [Color(0xFF184E5D), Color(0xFF123B46), Color(0xFF0C2931)],
  );

  static const LinearGradient tealGradient = LinearGradient(
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
    colors: [Color(0xFF1FB2A0), Color(0xFF138577)],
  );

  static const LinearGradient goldGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF3C363), Color(0xFFD9A441)],
  );

  static const LinearGradient splashGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF154450), Color(0xFF103640), Color(0xFF092127)],
  );
}
