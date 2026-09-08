import 'package:flutter/material.dart';
import 'local_ledger_store.dart';

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
          Text('ملخص الدفتر', style: Theme.of(context).textTheme.titleLarge),
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
                        color: Theme.of(
                          context,
                        ).colorScheme.primaryContainer.withValues(alpha: .35),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(item.$3, size: 20),
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
