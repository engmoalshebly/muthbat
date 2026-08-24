/// مسارات الأصول والملفات المتجهية المعتمدة
class AssetPaths {
  AssetPaths._();

  static const String _baseLogos = 'assets/logos';

  /// الشعار الكامل: الأيقونة + مُثبَت + MUTHBAT + الشعار التسويقي
  static const String logoPrimary = '$_baseLogos/muthbat_logo_primary.svg';

  /// الشعار العربي: الأيقونة + مُثبَت
  static const String logoArabic = '$_baseLogos/muthbat_logo_arabic.svg';

  /// الأيقونة الهندسية فقط: الرمز الموثق للعلامة
  static const String logoIcon = '$_baseLogos/muthbat_icon.svg';

  /// الشعار باللون الأبيض للخلفيات الداكنة وشاشة البداية
  static const String logoWhite = '$_baseLogos/muthbat_logo_white.svg';

  /// الشعار الرسمي عالي الدقة (PNG)
  static const String logoPng = '$_baseLogos/muthbat_logo.png';

  /// أيقونة التطبيق الرسمية عالية الدقة (PNG)
  static const String iconPng = '$_baseLogos/muthbat_icon.png';

  /// خلفية وشعار البداية (Splash PNG)
  static const String splashPng = '$_baseLogos/muthbat_splash.png';
}
