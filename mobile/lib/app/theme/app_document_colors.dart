import 'package:pdf/pdf.dart';
import 'app_colors.dart';

/// Central palette for exported documents.
class AppDocumentColors {
  AppDocumentColors._();

  static PdfColor get primary => PdfColor.fromInt(AppColors.primary.toARGB32());
  static PdfColor get ink => PdfColor.fromInt(AppColors.textPrimary.toARGB32());
  static PdfColor get muted =>
      PdfColor.fromInt(AppColors.textSecondary.toARGB32());
  static PdfColor get background =>
      PdfColor.fromInt(AppColors.backgroundLight.toARGB32());
  static PdfColor get border =>
      PdfColor.fromInt(AppColors.borderLight.toARGB32());
  static PdfColor get debt => PdfColor.fromInt(AppColors.debt.toARGB32());
  static PdfColor get credit =>
      PdfColor.fromInt(AppColors.customerCredit.toARGB32());
  static PdfColor get tableHeader => primary;
}
