import 'package:flutter/material.dart';

/// نظام ألوان هوية «مُثبَت | MUTHBAT» المعتمد
class AppColors {
  AppColors._();

  // Compact financial summary surface.
  static const Color summarySurface = primary;
  static const Color summaryBorder = primary;

  /// Uniform official brand green for filled cards across all workspaces.
  static const LinearGradient cardGradient = LinearGradient(
    colors: [summarySurface, summarySurface],
  );

  static const Color white70 = Color(0xB3FFFFFF);
  static const Color white60 = Color(0x99FFFFFF);
  static const Color white54 = Color(0x8AFFFFFF);
  static const Color white24 = Color(0x3DFFFFFF);
  static const Color black54 = Color(0x8A000000);
  static const Color black87 = Color(0xDD000000);

  // Shared surfaces, illustration accents, platform messaging, and primitives.
  static const Color surfaceContainerSoft = Color(0xFFF1F5F9);
  static const Color surfaceContainerStrong = Color(0xFFE2E8F0);
  static const Color fieldSurface = backgroundLight;
  static const Color goldInk = Color(0xFF4A3408);
  static const Color illustrationHalo = primaryContainer;
  static const Color illustrationApricot = Color(0xFFFFB659);
  static const Color illustrationBlueDeep = primaryDark;
  static const Color illustrationPeach = Color(0xFFFFB879);
  static const Color illustrationGreenInk = Color(0xFF086D58);
  static const Color illustrationGoldLight = Color(0xFFFFDF9C);
  static const Color illustrationGold = Color(0xFFFFB84E);
  static const Color illustrationGoldBorder = Color(0xFFFFE8BD);
  static const Color illustrationGoldInk = Color(0xFFB26916);
  static const Color illustrationLine = borderLight;
  static const Color choiceBorder = borderLight;
  static const Color roleLocalSurface = Color(0xFFFFEED7);
  static const Color roleCustomerInk = Color(0xFF087661);
  static const Color roleLocalInk = Color(0xFFA65F0B);
  static const Color entryCardBorder = borderLight;
  static const Color fieldLabel = textSecondary;
  static const Color fieldBorder = borderLight;
  static const Color segmentBorder = borderLight;
  static const Color entryBackgroundBlue = primaryContainer;
  static const Color entryBackgroundWhite = backgroundLight;
  static const Color entryBackgroundMint = Color(0xFFF0F8F3);
  static const Color blueGlow = Color(0xFFC1E4D2);
  static const Color mintGlow = Color(0xFFD5EBDF);
  static const Color messagingSurface = Color(0xFFE7F8EE);
  static const Color messagingGreen = Color(0xFF25D366);
  static const Color messagingInk = Color(0xFF0F5132);
  static const Color messagingTeal = Color(0xFF128C7E);
  static const Color neutralBorder = Color(0xFFE5E7EB);
  static const Color successSurfaceSoft = Color(0xFFF0FDF4);
  static const Color successBorder = Color(0xFFBBF7D0);
  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF000000);
  static const Color transparent = Color(0x00000000);
  static const Color neutralGrey200 = Color(0xFFEEEEEE);
  static const Color neutralGrey300 = Color(0xFFE0E0E0);
  static const Color warningStrong = Color(0xFFEF6C00);
  static const Color orange = warning;
  static const Color red = error;
  static const Color redAccent = error;
  static const Color blueGrey = Color(0xFF607D8B);

  // --- الألوان الأساسية (Primary Brand Palette) ---
  /// Functional green (#16845B) - لون الثقة والرسوخ المالي
  static const Color primary = success;
  static const Color primaryLight = Color(0xFF278A66);
  static const Color primaryDark = Color(0xFF106344);
  static const Color primaryContainer = Color(0xFFE7F4ED);

  // --- اللون الثانوي (Secondary Brand Palette) ---
  /// Deep green (#106344) - لون التقنية والحداثة والنشاط المالي
  static const Color secondary = primaryDark;
  static const Color secondaryLight = primaryLight;
  static const Color secondaryDark = Color(0xFF0D5138);
  static const Color secondaryContainer = primaryContainer;

  // --- اللون المميز (Accent Color) ---
  /// Pending amber (#E69A23) - رمز التوثيق وعلامة الاعتماد
  static const Color accentGold = warning;
  static const Color accentGoldLight = Color(0xFFFFD68A);
  static const Color accentGoldDark = Color(0xFF965A0D);
  static const Color accentGoldContainer = Color(0xFFFFF1D8);

  // --- الخلفيات والأسطح (Backgrounds & Surfaces) ---
  static const Color backgroundLight = Color(0xFFF8FAFC);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color surfaceElevated = Color(0xFFFFFFFF);
  static const Color navBackground = Color(0xFFFFFFFF);
  static const Color navInactive = textMuted;

  static const Color backgroundDark = Color(0xFF0F172A);
  static const Color surfaceDark = Color(0xFF1E293B);
  static const Color surfaceDarkElevated = Color(0xFF334155);

  // --- النصوص (Typography Colors) ---
  static const Color textPrimary = Color(0xFF1E293B);
  static const Color textSecondary = Color(0xFF334155);
  static const Color textMuted = Color(0xFF526176);
  static const Color textWhite = Color(0xFFFFFFFF);
  static const Color textWhiteSecondary = Color(0xFFE7F4ED);

  // --- الحدود والفواصل (Borders & Dividers) ---
  static const Color borderLight = Color(0xFFE2E8F0);
  static const Color borderSubtle = Color(0xFFF1F5F9);
  static const Color borderDark = Color(0xFF475569);

  // --- الحالات التشغيلية والمالية (Semantic & Financial Statuses) ---
  /// السداد، التحصيل، الدفعات، الحركات المؤكدة
  static const Color success = Color(0xFF16845B);
  static const Color successLight = Color(0xFFE5F6EE);
  static const Color paymentGreen = success;

  /// بانتظار التأكيد، المراجعة، التنبيهات
  static const Color warning = Color(0xFFE69A23);
  static const Color warningLight = Color(0xFFFDF2E2);

  /// الديون المتأخرة، الاعتراضات المفتوحة، الأخطاء
  static const Color error = Color(0xFFD9534F);
  static const Color errorLight = Color(0xFFFBECEC);
  static const Color debtRed = error;

  // Financial meaning is relative to the person viewing the balance.
  static const Color receivable = success;
  static const Color payable = error;
  static const Color pending = warning;
  static const Color settled = success;
  // Customer status is distinct from the owner's receivable/payable colors.
  static const Color customerCredit = Color(0xFF27648A);
  static Color customerStatusColor(num balance) => balance > 0
      ? debt
      : balance < 0
      ? customerCredit
      : settled;
  static const Color debt = error;
  static const Color payment = success;
  static const Color discount = warning;

  /// Movement type colors; balances use the viewer's perspective instead.
  static Color transactionColor(String type) => switch (type) {
    'debt' => debt,
    'payment' => payment,
    'discount' => discount,
    'reversal' => textMuted,
    _ => textSecondary,
  };

  /// Positive = owed to the viewer; negative = owed by the viewer.
  static Color balanceColor(num amount) => amount > 0
      ? receivable
      : amount < 0
      ? payable
      : settled;

  /// حدود متوسطة
  static const Color borderMedium = Color(0xFFCBD5E1);

  /// معلومات عامة، إشعارات الربط
  static const Color info = textSecondary;
  static const Color infoLight = surfaceContainerSoft;

  // --- ألوان شارات التصنيف (Category Badges) ---
  static const Color badgeGoodsBg = primaryContainer;
  static const Color badgeGoodsText = primaryDark;
  static const Color badgeCashBg = Color(0xFFE8F5EE);
  static const Color badgeCashText = Color(0xFF1B6B4A);
  static const Color badgeServiceBg = Color(0xFFFFF1D8);
  static const Color badgeServiceText = Color(0xFF8B6B1F);
  static const Color badgeTransferBg = surfaceContainerSoft;
  static const Color badgeTransferText = textSecondary;
  static const Color badgeRefBg = primaryContainer;
  static const Color badgeRefText = primary;

  // --- تدرجات اللونية الفاخرة (Gradients) ---
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
    colors: [primaryLight, primary, primaryDark],
  );

  static const LinearGradient tealGradient = LinearGradient(
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
    colors: [secondaryLight, secondary],
  );

  static const LinearGradient goldGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accentGoldLight, accentGold],
  );

  static const LinearGradient splashGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [primaryLight, primary, primaryDark],
  );
}
