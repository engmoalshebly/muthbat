import '../../../../core/database/app_database.dart';
import '../../../../core/config/supabase_config.dart';
import '../../../../core/security/cloud_session.dart';
import 'package:muthbat/shared/widgets/top_notice.dart';
import 'dart:io';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/brand_logo.dart';
import '../../../../shared/widgets/custom_button.dart';
import '../../../../core/finance/currency_info.dart';
import '../../data/models/business_customer_model.dart';
import '../../data/models/statement_model.dart';
import '../../data/local_statement_pdf.dart';

class StatementPreviewScreen extends StatelessWidget {
  final StatementModel statement;
  final BusinessCustomerModel customer;

  const StatementPreviewScreen({
    super.key,
    required this.statement,
    required this.customer,
  });

  String get _pdfFileName {
    final safeCustomer = customer.localDisplayName.trim().replaceAll(
      RegExp(r'[^\u0600-\u06FFa-zA-Z0-9_-]+'),
      '_',
    );
    final currencyLabel = statement.combinedStatements.length > 1
        ? statement.combinedStatements
              .map((item) => item.currencyCode)
              .join('_')
        : statement.currencyCode;
    return 'كشف_حساب_${safeCustomer}_$currencyLabel';
  }

  Future<Uint8List> _downloadPdfBytes() async {
    if (statement.id.startsWith('statement-local-')) {
      return localStatementPdf(statement, customer.localDisplayName);
    }
    requireCloudSession(
      Supabase.instance.client,
      AppDatabase.instance.accountId,
    );
    var url = statement.downloadUrl;
    if (statement.combinedStatements.length > 1) {
      final response = await Supabase.instance.client.functions.invoke(
        'combine-statements',
        body: {
          'statementIds': statement.combinedStatements
              .map((item) => item.id)
              .toList(),
        },
      );
      final data = response.data;
      if (data is! Map || data['signedUrl'] is! String) {
        throw const FormatException('invalid_combined_statement_url');
      }
      final signedUri = Uri.parse(data['signedUrl'] as String);
      final apiUri = Uri.parse(SupabaseConfig.effectiveUrl);
      url = signedUri
          .replace(
            scheme: apiUri.scheme,
            host: apiUri.host,
            port: apiUri.hasPort ? apiUri.port : null,
          )
          .toString();
    } else if (statement.pdfObjectPath != null) {
      url = await Supabase.instance.client.storage
          .from('statements')
          .createSignedUrl(statement.pdfObjectPath!, 300)
          .timeout(const Duration(seconds: 15));
    }
    if (url == null || url.isEmpty) {
      throw StateError('pdf_not_ready');
    }
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 45));
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    final bytes = response.bodyBytes;
    if (bytes.length < 5 || String.fromCharCodes(bytes.take(5)) != '%PDF-') {
      throw const FormatException('invalid_pdf');
    }
    return bytes;
  }

  void _showWorking(BuildContext context, String message) {
    TopNotice.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.white,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(message)),
            ],
          ),
          duration: const Duration(minutes: 1),
        ),
      );
  }

  void _showPdfError(BuildContext context, Object error) {
    if (!context.mounted) return;
    TopNotice.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'تعذر الحصول على ملف PDF. تحقق من الشبكة ثم أنشئ التقرير مجدداً إذا انتهت صلاحية الرابط.',
          ),
          backgroundColor: AppColors.error,
        ),
      );
  }

  Future<void> _sharePdf(BuildContext context) async {
    _showWorking(context, 'جاري تجهيز ملف PDF للمشاركة...');
    try {
      final bytes = await _downloadPdfBytes();
      final tempDir = await getTemporaryDirectory();
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}$_pdfFileName.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);
      if (!context.mounted) return;
      TopNotice.of(context).hideCurrentSnackBar();
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/pdf')],
          fileNameOverrides: ['$_pdfFileName.pdf'],
          title: 'مشاركة كشف الحساب',
          text: 'كشف حساب العميل ${customer.localDisplayName}',
          sharePositionOrigin:
              (context.findRenderObject() as RenderBox?) == null
              ? null
              : (context.findRenderObject() as RenderBox).localToGlobal(
                      Offset.zero,
                    ) &
                    (context.findRenderObject() as RenderBox).size,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      _showPdfError(context, error);
    }
  }

  Future<void> _savePdf(BuildContext context) async {
    _showWorking(context, 'جاري تنزيل ملف PDF...');
    try {
      final bytes = await _downloadPdfBytes();
      final savedPath = await FileSaver.instance.saveFile(
        name: _pdfFileName,
        bytes: bytes,
        fileExtension: 'pdf',
        mimeType: MimeType.pdf,
      );
      if (!context.mounted) return;
      TopNotice.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('تم تنزيل ملف PDF بنجاح\n$savedPath'),
            backgroundColor: AppColors.success,
          ),
        );
    } catch (error) {
      _showPdfError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (statement.combinedStatements.length > 1) {
      return _buildCombinedPreview(context);
    }
    final isLocalPending = statement.downloadUrl == null;
    final currencyFormatter = NumberFormat('#,##0.##');
    final currencySymbol = CurrencyCatalog.forCode(
      statement.currencyCode,
    ).symbol;
    final dateFormat = DateFormat('yyyy/MM/dd');
    final from = dateFormat.format(DateTime.parse(statement.periodFrom));
    final to = dateFormat.format(DateTime.parse(statement.periodTo));

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: AppColors.primaryDark,
        elevation: 0,
        title: Text(
          isLocalPending ? 'كشف حساب محلي' : 'كشف حساب موثق',
          style: AppTypography.titleMedium(color: AppColors.white),
        ),
        actions: [
          if (!isLocalPending)
            IconButton(
              tooltip: 'نسخ رمز التحقق',
              icon: const Icon(AppIcons.copy, color: AppColors.accentGold),
              onPressed: () {
                Clipboard.setData(
                  ClipboardData(text: statement.verificationCode),
                );
                TopNotice.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'تم نسخ رمز التحقق: ${statement.verificationCode}',
                    ),
                    backgroundColor: AppColors.primaryDark,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // بطاقة شهادة كشف الحساب الرسمية
            Container(
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: AppColors.accentGold.withValues(alpha: 0.5),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.accentGold.withValues(alpha: 0.1),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // ترويسة الشهادة الذهبية
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    decoration: const BoxDecoration(
                      gradient: AppColors.cardGradient,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(22),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const BrandLogo.white(width: 110, height: 24),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.accentGold.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: AppColors.accentGold.withValues(
                                alpha: 0.4,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                AppIcons.shieldCheck,
                                size: 14,
                                color: AppColors.accentGold,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isLocalPending
                                    ? 'محفوظ على الجهاز'
                                    : 'موثق رسمياً',
                                style: const TextStyle(
                                  color: AppColors.accentGold,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        // اسم العميل والفترة
                        Text(
                          customer.localDisplayName,
                          style: AppTypography.titleLarge(
                            color: AppColors.textPrimary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'عن الفترة من $from إلى $to',
                          style: AppTypography.caption(
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 20),

                        if (isLocalPending)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.warning.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text(
                              'الكشف جاهز من بيانات الجهاز. تعمل مزامنة النسخة الموثقة في الخلفية.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        if (isLocalPending) const SizedBox(height: 16),

                        // رمز التحقق الرسمي
                        if (!isLocalPending)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.accentGoldContainer,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: AppColors.accentGold.withValues(
                                  alpha: 0.4,
                                ),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'رمز التحقق الرقمي',
                                      style: AppTypography.caption(
                                        color: AppColors.accentGoldDark,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      statement.verificationCode,
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 16,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 1.5,
                                        color: AppColors.primaryDark,
                                      ),
                                    ),
                                  ],
                                ),
                                IconButton(
                                  icon: const Icon(
                                    AppIcons.copy,
                                    color: AppColors.accentGoldDark,
                                    size: 20,
                                  ),
                                  onPressed: () {
                                    Clipboard.setData(
                                      ClipboardData(
                                        text: statement.verificationCode,
                                      ),
                                    );
                                    TopNotice.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('تم نسخ رمز التحقق'),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 20),

                        // شبكة الملخص المالي
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppColors.backgroundLight,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppColors.borderLight),
                          ),
                          child: Column(
                            children: [
                              _buildMetricRow(
                                'الرصيد الافتتاحي',
                                statement.openingBalance,
                                AppColors.textPrimary,
                                currencyFormatter,
                                currencySymbol,
                              ),
                              const Divider(height: 16),
                              _buildMetricRow(
                                'إجمالي الديون (+)',
                                statement.totalDebits,
                                AppColors.debtRed,
                                currencyFormatter,
                                currencySymbol,
                              ),
                              const Divider(height: 16),
                              _buildMetricRow(
                                'إجمالي السدادات والخصم (-)',
                                statement.totalCredits,
                                AppColors.paymentGreen,
                                currencyFormatter,
                                currencySymbol,
                              ),
                              const Divider(height: 16, thickness: 1.5),
                              _buildMetricRow(
                                'الرصيد الختامي المستحق',
                                statement.closingBalance,
                                AppColors.primary,
                                currencyFormatter,
                                currencySymbol,
                                isBold: true,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),

                        // بصمة التشفير SHA-256
                        if (statement.snapshotSha256Hex != null) ...[
                          Row(
                            children: [
                              const Icon(
                                AppIcons.shieldCheck,
                                size: 14,
                                color: AppColors.textSecondary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'بصمة السلامة المالية (SHA-256):',
                                style: AppTypography.caption(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: AppColors.backgroundLight,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              statement.snapshotSha256Hex!,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 9,
                                color: AppColors.textSecondary,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ).animate().scale(duration: 200.ms, curve: Curves.easeOut),

            const SizedBox(height: 24),

            // أزرار الإجراء
            if (statement.downloadUrl != null ||
                statement.id.startsWith('statement-local-')) ...[
              CustomButton(
                text: 'فتح / تحميل كشف PDF',
                variant: ButtonVariant.primary,
                onPressed: () async {
                  if (statement.downloadUrl == null) {
                    await _savePdf(context);
                    return;
                  }
                  try {
                    final uri = Uri.parse(statement.downloadUrl!);
                    // لا نستخدم canLaunchUrl كحارس؛ بعض إصدارات Android تعيد
                    // false رغم أن المتصفح قادر على فتح الرابط فعلياً.
                    final opened = await launchUrl(
                      uri,
                      mode: LaunchMode.externalApplication,
                    );
                    if (!opened && context.mounted) {
                      TopNotice.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'تعذر فتح ملف PDF. تأكد من وجود متصفح أو قارئ PDF.',
                          ),
                          backgroundColor: AppColors.error,
                        ),
                      );
                    }
                  } catch (error) {
                    if (context.mounted) {
                      TopNotice.of(context).showSnackBar(
                        SnackBar(
                          content: Text('تعذر فتح ملف PDF: $error'),
                          backgroundColor: AppColors.error,
                        ),
                      );
                    }
                  }
                },
                icon: AppIcons.pdf,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: CustomButton(
                      text: 'مشاركة PDF',
                      variant: ButtonVariant.primary,
                      onPressed: () => _sharePdf(context),
                      icon: AppIcons.share,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: CustomButton(
                      text: 'تنزيل PDF',
                      variant: ButtonVariant.secondary,
                      onPressed: () => _savePdf(context),
                      icon: Icons.download_rounded,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],

            CustomButton(
              text: isLocalPending
                  ? 'نسخ ملخص التقرير المحلي'
                  : 'مشاركة كود التحقق والملخص',
              variant: ButtonVariant.secondary,
              onPressed: () {
                final shareText =
                    '''
كشف حساب من تطبيق مُثبَت
العميل: ${customer.localDisplayName}
الفترة: من $from إلى $to
الرصيد الختامي: ${currencyFormatter.format(statement.closingBalance)} $currencySymbol
${isLocalPending ? 'الحالة: نسخة من بيانات الجهاز' : 'رمز التحقق الرسمي: ${statement.verificationCode}'}
''';
                Clipboard.setData(ClipboardData(text: shareText));
                TopNotice.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('تم نسخ نص كشف الحساب للمشاركة'),
                    backgroundColor: AppColors.success,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              icon: AppIcons.share,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCombinedPreview(BuildContext context) {
    final formatter = NumberFormat('#,##0.##');
    final dateFormat = DateFormat('yyyy/MM/dd');
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(title: const Text('كشف كل العملات')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            customer.localDisplayName,
            style: AppTypography.titleLarge(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            'من ${dateFormat.format(DateTime.parse(statement.periodFrom))} إلى ${dateFormat.format(DateTime.parse(statement.periodTo))}',
          ),
          const SizedBox(height: 8),
          const Text(
            'كل عملة في صفحة مستقلة من ملف PDF، دون جمع أرصدة العملات المختلفة.',
          ),
          const SizedBox(height: 16),
          for (final item in statement.combinedStatements) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.currencyCode,
                      style: AppTypography.titleMedium(
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'الرصيد الافتتاحي: ${formatter.format(item.openingBalance)} ${item.currencyCode}',
                    ),
                    Text(
                      'الديون: ${formatter.format(item.totalDebits)} ${item.currencyCode}',
                    ),
                    Text(
                      'السدادات والخصومات: ${formatter.format(item.totalCredits)} ${item.currencyCode}',
                    ),
                    Text(
                      'الرصيد الختامي: ${formatter.format(item.closingBalance)} ${item.currencyCode}',
                    ),
                    Text(
                      item.id.startsWith('statement-local-')
                          ? 'نسخة من بيانات الجهاز'
                          : 'رمز التحقق: ${item.verificationCode}',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _savePdf(context),
            icon: const Icon(Icons.download_rounded),
            label: const Text('تنزيل PDF لكل العملات'),
          ),
          OutlinedButton.icon(
            onPressed: () => _sharePdf(context),
            icon: const Icon(Icons.share_rounded),
            label: const Text('مشاركة PDF'),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricRow(
    String label,
    double amount,
    Color color,
    NumberFormat formatter,
    String symbol, {
    bool isBold = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: isBold ? 14 : 12,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            color: isBold ? AppColors.textPrimary : AppColors.textSecondary,
          ),
        ),
        Text(
          '${formatter.format(amount)} $symbol',
          style: TextStyle(
            fontSize: isBold ? 16 : 13,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      ],
    );
  }
}
