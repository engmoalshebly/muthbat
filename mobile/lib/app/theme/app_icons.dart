import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'app_colors.dart';

/// نظام الأيقونات المالي المركزي الموحد لمنصة «مُثبَت | MUTHBAT»
/// يعتمد على حزمة Lucide Icons مع توحيد الدلالات البصرية والألوان المالية.
class AppIcons {
  AppIcons._();

  // ==================== 1. التنقل والأقسام الرئيسية ====================
  static const IconData home = LucideIcons.house;
  static const IconData customers = LucideIcons.users;
  static const IconData singleCustomer = LucideIcons.userRound;
  static const IconData reports = LucideIcons.chartColumn;
  static const IconData profile = LucideIcons.userRoundCog;
  static const IconData settings = LucideIcons.settings;
  static const IconData store = LucideIcons.store;
  static const IconData team = LucideIcons.usersRound;

  // ==================== 2. العمليات المالية والقيود ====================
  static const IconData wallet = LucideIcons.wallet;
  static const IconData balance = LucideIcons.circleDollarSign;
  static const IconData cash = LucideIcons.banknote;
  static const IconData creditCard = LucideIcons.creditCard;
  
  /// دين جديد (حركة مدينة - أحمر)
  static const IconData debt = LucideIcons.arrowUpRight;
  static const IconData addDebt = LucideIcons.circlePlus;

  /// سداد وقبض (حركة دائنة - أخضر)
  static const IconData payment = LucideIcons.arrowDownLeft;
  static const IconData receivePayment = LucideIcons.circleCheckBig;

  /// خصم تجاري
  static const IconData discount = LucideIcons.badgePercent;

  /// عكس قيد
  static const IconData reversal = LucideIcons.rotateCcw;

  /// كشف حساب وسندات
  static const IconData statement = LucideIcons.fileText;
  static const IconData receipt = LucideIcons.receiptText;
  static const IconData pdf = LucideIcons.fileSpreadsheet;
  static const IconData qrCode = LucideIcons.qrCode;

  // ==================== 3. الأمان، الاعتراضات، والمزامنة ====================
  static const IconData shieldCheck = LucideIcons.shieldCheck;
  static const IconData lock = LucideIcons.lock;
  static const IconData key = LucideIcons.keyRound;
  static const IconData dispute = LucideIcons.badgeAlert;
  static const IconData warning = LucideIcons.triangleAlert;
  static const IconData notifications = LucideIcons.bell;
  
  /// المزامنة والحفظ السحابي
  static const IconData sync = LucideIcons.refreshCw;
  static const IconData synced = LucideIcons.cloudCheck;
  static const IconData offline = LucideIcons.cloudOff;
  static const IconData pendingUpload = LucideIcons.cloudUpload;

  // ==================== 4. الأدوات والتواصل ====================
  static const IconData search = LucideIcons.search;
  static const IconData filter = LucideIcons.slidersHorizontal;
  static const IconData calendar = LucideIcons.calendar;
  static const IconData share = LucideIcons.share2;
  static const IconData whatsapp = LucideIcons.messageCircle;
  static const IconData phone = LucideIcons.phone;
  static const IconData copy = LucideIcons.copy;
  static const IconData check = LucideIcons.check;
  static const IconData close = LucideIcons.x;
  static const IconData info = LucideIcons.info;
  static const IconData help = LucideIcons.circleHelp;

  // ==================== 5. الأسهم والتوجيه (متوافقة مع RTL) ====================
  static const IconData chevronStart = LucideIcons.chevronRight; // RTL Back
  static const IconData chevronEnd = LucideIcons.chevronLeft;   // RTL Forward
  static const IconData chevronDown = LucideIcons.chevronDown;
  static const IconData chevronUp = LucideIcons.chevronUp;
  static const IconData arrowStart = LucideIcons.arrowRight;
  static const IconData arrowEnd = LucideIcons.arrowLeft;
}

/// ويدجت صندوق الأيقونة المالي بتصميم FinTech عصري مع خلفية ناعمة
class AppIconBox extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final Color? backgroundColor;
  final double size;
  final double padding;
  final double borderRadius;
  final VoidCallback? onTap;

  const AppIconBox({
    super.key,
    required this.icon,
    this.color,
    this.backgroundColor,
    this.size = 20,
    this.padding = 10,
    this.borderRadius = 12,
    this.onTap,
  });

  /// نمط مالي: دين جديد (أحمر)
  factory AppIconBox.debt({
    double size = 20,
    double padding = 10,
    VoidCallback? onTap,
  }) {
    return AppIconBox(
      icon: AppIcons.debt,
      color: AppColors.debtRed,
      backgroundColor: AppColors.debtRed.withValues(alpha: 0.12),
      size: size,
      padding: padding,
      onTap: onTap,
    );
  }

  /// نمط مالي: سداد وقبض (أخضر)
  factory AppIconBox.payment({
    double size = 20,
    double padding = 10,
    VoidCallback? onTap,
  }) {
    return AppIconBox(
      icon: AppIcons.payment,
      color: AppColors.paymentGreen,
      backgroundColor: AppColors.paymentGreen.withValues(alpha: 0.12),
      size: size,
      padding: padding,
      onTap: onTap,
    );
  }

  /// نمط مالي: محفظة ورصيد (كحلي بترولي)
  factory AppIconBox.primary({
    required IconData icon,
    double size = 20,
    double padding = 10,
    VoidCallback? onTap,
  }) {
    return AppIconBox(
      icon: icon,
      color: AppColors.primary,
      backgroundColor: AppColors.primary.withValues(alpha: 0.10),
      size: size,
      padding: padding,
      onTap: onTap,
    );
  }

  /// نمط مالي: توثيق وذهب (ذهبي معتمد)
  factory AppIconBox.gold({
    required IconData icon,
    double size = 20,
    double padding = 10,
    VoidCallback? onTap,
  }) {
    return AppIconBox(
      icon: icon,
      color: AppColors.accentGoldDark,
      backgroundColor: AppColors.accentGold.withValues(alpha: 0.14),
      size: size,
      padding: padding,
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? AppColors.primary;
    final effectiveBg = backgroundColor ?? effectiveColor.withValues(alpha: 0.10);

    Widget box = Container(
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: effectiveBg,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Icon(
        icon,
        size: size,
        color: effectiveColor,
      ),
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(borderRadius),
        child: box,
      );
    }

    return box;
  }
}
