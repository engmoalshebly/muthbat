import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../finance/currency_info.dart';
import '../../features/merchant/data/models/business_customer_model.dart';
import '../../features/merchant/data/models/ledger_entry_model.dart';

/// خدمة مشاركة وتصدير السندات وكشوفات الحساب (Offline Statement & Receipt Sharing)
/// تتيح للتاجر توثيق ومشاركة العمليات المالية مع العميل فورياً عبر واتساب بدون الحاجة للإنترنت.
class StatementSharingService {
  StatementSharingService._();

  /// صياغة ومشاركة سند مالي لقيد محدد عبر واتساب مباشرة
  static Future<bool> shareReceiptViaWhatsApp({
    required String businessName,
    required BusinessCustomerModel customer,
    required LedgerEntryModel entry,
  }) async {
    final currencySymbol = _currencySymbol(entry.currencyCode);
    final entryTypeTitle = entry.direction == 'debit'
        ? '🔴 قيد دين جديد (عليك)'
        : '🟢 سند قبض وسداد (لك)';
    final formattedDate = _formatDateTime(
      DateTime.tryParse(entry.occurredAt) ?? DateTime.now(),
    );
    final numberFormat = NumberFormat('#,##0.##', 'ar');

    final message = StringBuffer()
      ..writeln('📋 *سند مالي موثق — تطبيق مُثبَت*')
      ..writeln('━━━━━━━━━━━━━━━━━━━━')
      ..writeln('🏪 *المنشأة:* $businessName')
      ..writeln('👤 *العميل:* ${customer.localDisplayName}')
      ..writeln('📌 *نوع الحركة:* $entryTypeTitle')
      ..writeln(
        '💰 *المبلغ:* ${numberFormat.format(entry.amount)} $currencySymbol',
      )
      ..writeln('📝 *البيان:* ${entry.description.trim()}')
      ..writeln('📅 *التاريخ والوقت:* $formattedDate')
      ..writeln('━━━━━━━━━━━━━━━━━━━━')
      ..writeln('📊 *الرصيد الإجمالي الحالي:*')
      ..writeln(
        '👉 *${numberFormat.format(customer.currentBalance.abs())} $currencySymbol* ${_balanceLabel(customer.currentBalance)}',
      )
      ..writeln('━━━━━━━━━━━━━━━━━━━━')
      ..writeln('🔒 _سند مالي مؤمن إلكترونياً وغير قابل للتعديل_');

    return await _launchWhatsApp(
      phone: customer.phone,
      message: message.toString(),
    );
  }

  /// صياغة ومشاركة ملخص كشف حساب شامل للعميل عبر واتساب
  static Future<bool> shareCustomerSummaryViaWhatsApp({
    required String businessName,
    required BusinessCustomerModel customer,
    List<LedgerEntryModel>? recentEntries,
  }) async {
    final numberFormat = NumberFormat('#,##0.##', 'ar');
    final formattedDate = _formatDateTime(DateTime.now());

    final message = StringBuffer()
      ..writeln('📑 *كشف حساب مالي — تطبيق مُثبَت*')
      ..writeln('━━━━━━━━━━━━━━━━━━━━')
      ..writeln('🏪 *المنشأة:* $businessName')
      ..writeln('👤 *العميل:* ${customer.localDisplayName}')
      ..writeln('📅 *تاريخ الاستخراج:* $formattedDate')
      ..writeln('━━━━━━━━━━━━━━━━━━━━')
      ..writeln('📊 *الأرصدة الحالية حسب العملة:*');

    if (customer.currencyBalances.isNotEmpty) {
      customer.currencyBalances.forEach((curr, bal) {
        final sym = _currencySymbol(curr);
        final label = _balanceLabel(bal);
        message.writeln('• *${numberFormat.format(bal.abs())} $sym* $label');
      });
    } else {
      final sym = _currencySymbol('YER');
      message.writeln(
        '• *${numberFormat.format(customer.currentBalance.abs())} $sym* ${_balanceLabel(customer.currentBalance)}',
      );
    }

    if (recentEntries != null && recentEntries.isNotEmpty) {
      message.writeln('━━━━━━━━━━━━━━━━━━━━');
      message.writeln('📋 *آخر العمليات والحركات المالية:*');
      final itemsToShow = recentEntries.take(5).toList();
      for (final item in itemsToShow) {
        final sign = item.direction == 'debit' ? '(+) دين' : '(-) سداد';
        final sym = _currencySymbol(item.currencyCode);
        final itemDate = DateFormat(
          'yyyy/MM/dd',
          'ar',
        ).format(DateTime.tryParse(item.occurredAt) ?? DateTime.now());
        message.writeln(
          '▫️ $itemDate: ${numberFormat.format(item.amount)} $sym $sign — ${item.description}',
        );
      }
    }

    message
      ..writeln('━━━━━━━━━━━━━━━━━━━━')
      ..writeln('💬 _يرجى مراجعة الحساب والتواصل في حال وجود أي استفسار_')
      ..writeln('🔒 _نظام مُثبَت المالي المحمي_');

    return await _launchWhatsApp(
      phone: customer.phone,
      message: message.toString(),
    );
  }

  static String _balanceLabel(double balance) {
    if (balance > 0) return '(مطلوب منك لصالح المحل)';
    if (balance < 0) return '(مستحق لك طرف المحل)';
    return '(الحساب خالص ومسدد)';
  }

  static String _currencySymbol(String code) {
    return CurrencyCatalog.forCode(code).symbol;
  }

  static String _formatDateTime(DateTime dt) {
    final dateStr = DateFormat('yyyy/MM/dd', 'ar').format(dt);
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final period = dt.hour >= 12 ? 'م' : 'ص';
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$dateStr في $hour:$minute $period';
  }

  static Future<bool> _launchWhatsApp({
    String? phone,
    required String message,
  }) async {
    final cleanPhone = phone?.replaceAll(RegExp(r'[^0-9]'), '') ?? '';
    final encodedMessage = Uri.encodeComponent(message);

    // 1. تجربة الرابط المباشر لتطبيق واتساب
    final appUrl = cleanPhone.isNotEmpty
        ? Uri.parse('whatsapp://send?phone=$cleanPhone&text=$encodedMessage')
        : Uri.parse('whatsapp://send?text=$encodedMessage');

    try {
      if (await canLaunchUrl(appUrl)) {
        return await launchUrl(appUrl, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}

    // 2. الرابط البديل عبر wa.me
    final webUrl = cleanPhone.isNotEmpty
        ? Uri.parse('https://wa.me/$cleanPhone?text=$encodedMessage')
        : Uri.parse('https://wa.me/?text=$encodedMessage');

    try {
      return await launchUrl(webUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      return false;
    }
  }
}
