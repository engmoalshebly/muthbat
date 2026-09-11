import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';

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
    if (ownerId != null && ref.watch(authControllerProvider.select((s) => s.userId)) != ownerId) {
      return const Scaffold(body: Center(child: Text('تغير الحساب. افتح العملية من حسابك الحالي.')));
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
      'الوصف': entry['description']?.toString() ?? 'غير متاح',
      'التاريخ': date == null
          ? 'غير متاح'
          : DateFormat('yyyy/MM/dd • HH:mm').format(date.toLocal()),
      'حالة التأكيد': switch (entry['confirmation_status']) {
        'confirmed' => 'مؤكدة',
        'pending' => 'بانتظار التأكيد',
        _ => 'غير متاح',
      },
      'حالة الاعتراض': switch (entry['dispute_status']) {
        'open' => 'اعتراض مفتوح',
        'resolved' => 'تمت معالجة الاعتراض',
        _ => 'لا يوجد اعتراض مسجل',
      },
      if (entry['is_reversed'] == true)
        'حالة القيد': 'تم عكسه بقيد تصحيحي؛ الأصل محفوظ',
      'مرجع العملية': entry['id']?.toString() ?? 'غير متاح',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('تفاصيل عمليتي')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'نسخة من بيانات حسابك لدى البقالة',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          for (final field in fields.entries)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      field.key,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 6),
                    SelectableText(field.value),
                  ],
                ),
              ),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('عرض العملية لا يعني تأكيدها أو الإقرار بصحتها.'),
          ),
        ],
      ),
    );
  }
}
