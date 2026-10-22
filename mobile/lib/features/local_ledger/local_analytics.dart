import 'package:flutter/material.dart';
import 'local_ledger_store.dart';
import '../../app/theme/app_icons.dart';
import '../../app/theme/app_colors.dart';
import 'local_reports.dart';

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
    if (!summaryOnly) return LocalReports(document: document);
    final balances = <String, int>{};
    final entries = document['entries'] as List;
    for (final e in entries) {
      final amount = e['minor'] as int;
      balances.update(
        e['customer_id'],
        (v) => v + (e['direction'] == 'debit' ? amount : -amount),
        ifAbsent: () => e['direction'] == 'debit' ? amount : -amount,
      );
    }
    final receivables = balances.values
        .where((v) => v > 0)
        .fold<int>(0, (a, b) => a + b);
    final credit = balances.values
        .where((v) => v < 0)
        .fold<int>(0, (a, b) => a - b);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.summarySurface,
              border: Border.all(color: AppColors.summaryBorder),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceLight,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: const Icon(
                        AppIcons.wallet,
                        color: AppColors.primary,
                        size: 16,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'إجمالي المستحق لك',
                        style: TextStyle(
                          color: AppColors.textWhite,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${LocalLedgerStore.money(receivables)} ${document['currency']}',
                  style: const TextStyle(
                    color: AppColors.textWhite,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          AppIcons.customers,
                          size: 14,
                          color: AppColors.textWhiteSecondary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${(document['customers'] as List).length} عميل',
                          style: const TextStyle(
                            color: AppColors.textWhiteSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          AppIcons.receipt,
                          size: 14,
                          color: AppColors.textWhiteSecondary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${entries.length} عملية مسجلة',
                          style: const TextStyle(
                            color: AppColors.textWhiteSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (credit > 0) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceLight,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'أرصدة للعملاء: ${LocalLedgerStore.money(credit)} ${document['currency']}',
                      style: const TextStyle(
                        color: AppColors.payable,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
