import 'package:flutter/material.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_icons.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import '../widgets/customer_dispute_button.dart';

/// Read-only customer receipt. No merchant mutation controls are exposed.
class CustomerEntryDetailsScreen extends ConsumerWidget {
  const CustomerEntryDetailsScreen({
    super.key,
    required this.businessName,
    required this.entry,
    this.ownerId,
  });
  final String businessName;
  final Map<String, dynamic> entry;
  final String? ownerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ownerId != null &&
        ref.watch(authControllerProvider.select((s) => s.userId)) != ownerId) {
      return const Scaffold(
        body: Center(child: Text('تغير الحساب. افتح العملية من حسابك الحالي.')),
      );
    }
    final date = DateTime.tryParse(entry['occurred_at']?.toString() ?? '');
    final type =
        const {
          'debt': 'دين',
          'payment': 'دفعة',
          'discount': 'خصم',
          'reversal': 'قيد تصحيحي',
          'opening_balance': 'رصيد افتتاحي',
        }[entry['entry_type']] ??
        'عملية';
    final fields = <String, String>{
      'البقالة': businessName,
      'نوع العملية': type,
      'المبلغ':
          '${NumberFormat('#,##0.####').format(entry['amount'] ?? 0)} ${entry['currency_code'] ?? ''}',
      'الوصف': (entry['description']?.toString().trim().isNotEmpty ?? false)
          ? entry['description'].toString()
          : 'لم يُضف وصف لهذه الحركة',
      'التاريخ': date == null
          ? 'غير متاح'
          : DateFormat('yyyy/MM/dd • HH:mm').format(date.toLocal()),
      'حالة العملية': entry['is_reversed'] == true
          ? 'تم عكسها بقيد تصحيحي'
          : 'مسجلة في الحساب',
      'حالة الاعتراض': switch (entry['dispute_status']) {
        'open' => 'اعتراض مفتوح',
        'resolved' => 'تمت معالجة الاعتراض',
        _ => 'لا يوجد اعتراض مسجل',
      },
      if ((entry['dispute_resolution_note'] as String?)?.isNotEmpty == true)
        'رد التاجر': entry['dispute_resolution_note'] as String,
      if (entry['dispute_resolved_at'] != null)
        'تاريخ معالجة الاعتراض': DateFormat('yyyy/MM/dd • HH:mm').format(
          DateTime.parse(entry['dispute_resolved_at'] as String).toLocal(),
        ),
      if (entry['is_reversed'] == true)
        'حالة القيد': 'تم عكسه بقيد تصحيحي؛ الأصل محفوظ',
      'مرجع العملية': entry['id']?.toString() ?? 'غير متاح',
    };
    final accent = AppColors.transactionColor(entry['entry_type'].toString());
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundLight,
        elevation: 0,
        title: const Text(
          'تفاصيل الحركة',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: AppColors.cardGradient,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: AppColors.white.withValues(alpha: .16),
                      child: Icon(
                        AppIcons.transaction(entry['entry_type'].toString()),
                        color: AppColors.white,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        type,
                        style: const TextStyle(
                          color: AppColors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  fields['المبلغ'] ?? '',
                  style: const TextStyle(
                    color: AppColors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  fields['البقالة'] ?? businessName,
                  style: const TextStyle(color: AppColors.white70),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.notes_rounded, size: 18, color: accent),
                    const SizedBox(width: 7),
                    const Text(
                      'وصف الحركة',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SelectableText(
                  fields['الوصف']!,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.6,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: Column(
              children: [
                for (final field in fields.entries.where(
                  (f) => ![
                    'المبلغ',
                    'البقالة',
                    'نوع العملية',
                    'الوصف',
                  ].contains(f.key),
                ))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 100,
                          child: Text(
                            field.key,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SelectableText(
                            field.value,
                            textAlign: TextAlign.end,
                            style: const TextStyle(
                              fontSize: 12,
                              height: 1.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          CustomerDisputeButton(
            entry: entry,
            ownerId: ownerId,
            businessName: businessName,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            child: Text(
              'تُسجل العمليات مباشرة دون قبول أو رفض. يمكنك الاعتراض من تفاصيل العملية؛ الاعتراض لا يغير الرصيد حتى معالجة التاجر له.',
              style: TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
