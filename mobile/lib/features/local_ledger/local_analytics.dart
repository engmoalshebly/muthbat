import 'package:flutter/material.dart';
import 'local_ledger_store.dart';
import '../../app/theme/app_colors.dart';

class LocalAnalytics extends StatelessWidget {
  const LocalAnalytics({super.key, required this.document});
  final JsonMap document;
  @override
  Widget build(BuildContext context) {
    final balances = <String, int>{};
    final entries = document['entries'] as List;
    final reversed = entries
        .where((e) => e['reverses'] != null)
        .map((e) => e['reverses'])
        .toSet();
    int payments = 0, discounts = 0;
    for (final e in entries) {
      final amount = e['minor'] as int;
      balances.update(
        e['customer_id'],
        (v) => v + (e['direction'] == 'debit' ? amount : -amount),
        ifAbsent: () => e['direction'] == 'debit' ? amount : -amount,
      );
      if (!reversed.contains(e['id'])) {
        if (e['type'] == 'payment') payments += amount;
        if (e['type'] == 'discount') discounts += amount;
      }
    }
    final receivables = balances.values
        .where((v) => v > 0)
        .fold<int>(0, (a, b) => a + b);
    final credit = balances.values
        .where((v) => v < 0)
        .fold<int>(0, (a, b) => a - b);
    final debtors = balances.values.where((v) => v > 0).length;
    final items = [
      ('مستحق لك', receivables, Icons.account_balance_wallet_outlined),
      ('أرصدة للعملاء', credit, Icons.people_outline),
      ('دفعات مستلمة', payments, Icons.payments_outlined),
      ('خصومات ممنوحة', discounts, Icons.discount_outlined),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: AppColors.brandGradient,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.account_balance_wallet_outlined,
                      color: AppColors.accentGoldLight,
                    ),
                    SizedBox(width: 10),
                    Text(
                      'نظرة على بقالتك',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Text(
                  'إجمالي المستحق لك',
                  style: TextStyle(color: AppColors.textWhiteSecondary),
                ),
                const SizedBox(height: 6),
                Text(
                  '${LocalLedgerStore.money(receivables)} ${document['currency']}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${(document['customers'] as List).length} عميل  •  ${entries.length} حركة مسجلة',
                  style: const TextStyle(color: AppColors.accentGoldLight),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'ملخص الدفتر',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: AppColors.primary,
            ),
          ),
          Text(
            'كل الفترات • $debtors عملاء عليهم رصيد • ${document['currency']}',
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: items
                  .map(
                    (item) => Container(
                      width: (constraints.maxWidth - 8) / 2,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: AppColors.borderLight),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: item.$1 == 'دفعات مستلمة'
                                  ? AppColors.successLight
                                  : AppColors.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              item.$3,
                              size: 20,
                              color: AppColors.secondaryDark,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(item.$1),
                          Text(
                            LocalLedgerStore.money(item.$2),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'الدفعات والخصومات منفصلة، ولا تُحتسب العمليات المعكوسة ضمنهما.',
          ),
        ],
      ),
    );
  }
}
