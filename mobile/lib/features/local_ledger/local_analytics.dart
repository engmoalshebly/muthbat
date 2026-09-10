import 'package:flutter/material.dart';
import 'local_ledger_store.dart';
import 'local_palette.dart';
import '../../app/theme/app_colors.dart';

class LocalAnalytics extends StatelessWidget {
  const LocalAnalytics({
    super.key,
    required this.document,
    this.summaryOnly = false,
  });
  final JsonMap document;
  final bool summaryOnly;
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
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LocalPalette.hero,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.account_balance_wallet_outlined,
                      color: LocalPalette.gold,
                    ),
                    SizedBox(width: 10),
                    Text(
                      'نظرة على حساباتك',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'إجمالي المستحق لك',
                  style: TextStyle(color: AppColors.textWhiteSecondary),
                ),
                const SizedBox(height: 6),
                Text(
                  '${LocalLedgerStore.money(receivables)} ${document['currency']}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${(document['customers'] as List).length} عميل  •  ${entries.length} حركة مسجلة',
                  style: const TextStyle(color: LocalPalette.gold),
                ),
              ],
            ),
          ),
          if (!summaryOnly) ...[
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
            ...items.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(item.$3, color: LocalPalette.teal, size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          item.$1,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          '${LocalLedgerStore.money(item.$2)} ${document['currency']}',
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'الدفعات والخصومات منفصلة، ولا تُحتسب العمليات المعكوسة ضمنهما.',
            ),
            const SizedBox(height: 20),
            Text(
              'الحركات حسب التصنيف',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...LocalLedgerStore.categoryTotals(document).entries.map(
              (group) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.key,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 16,
                        runSpacing: 8,
                        children: group.value.entries
                            .map(
                              (total) => Text(
                                '${LocalLedgerStore.labels[total.key]}: ${LocalLedgerStore.money(total.value)} ${document['currency']}',
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
