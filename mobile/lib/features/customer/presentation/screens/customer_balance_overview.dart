import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../../app/theme/app_colors.dart';
import '../../data/models/customer_summary_model.dart';

/// Personal balances only: never nets different shops or currencies together.
class CustomerBalanceOverview extends StatelessWidget {
  const CustomerBalanceOverview({super.key, required this.summaries});
  final List<CustomerBusinessSummary> summaries;

  @override
  Widget build(BuildContext context) {
    final totals = <String, List<double>>{};
    for (final account in summaries) {
      final values = totals.putIfAbsent(account.currencyCode, () => [0, 0]);
      if (account.currentBalance > 0) {
        values[0] += account.currentBalance;
      } else {
        values[1] += account.currentBalance.abs();
      }
    }
    final format = NumberFormat('#,##0.##');
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'حساباتي لدى البقالات',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${summaries.map((s) => s.businessId).toSet().length} بقالات مرتبطة بحسابك',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          if (totals.isEmpty)
            const Text(
              'ستظهر أرصدتك هنا بعد ربط حسابك بالبقالات.',
              style: TextStyle(color: Colors.white),
            ),
          for (final total in totals.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    child: _amount(
                      'عليّ',
                      '${format.format(total.value[0])} ${total.key}',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _amount(
                      'لي',
                      '${format.format(total.value[1])} ${total.key}',
                    ),
                  ),
                ],
              ),
            ),
          const Text(
            'الأرصدة منفصلة لكل عملة • التفاصيل داخل كل بقالة',
            style: TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _amount(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: Colors.white70)),
      const SizedBox(height: 4),
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 19,
          fontWeight: FontWeight.bold,
        ),
      ),
    ],
  );
}
