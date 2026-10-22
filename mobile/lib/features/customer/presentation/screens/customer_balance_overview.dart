import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../../app/theme/app_colors.dart';
import '../../data/models/customer_summary_model.dart';

/// Compact customer portfolio header. Currency totals stay separate to avoid
/// presenting unlike currencies as one misleading amount.
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
      } else if (account.currentBalance < 0) {
        values[1] += account.currentBalance.abs();
      }
    }
    final shopsCount = summaries.map((s) => s.businessId).toSet().length;
    final format = NumberFormat('#,##0.##');

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.summarySurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'أرصدتك لدى المتاجر',
                      style: TextStyle(
                        color: AppColors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'ملخص الحساب',
                      style: TextStyle(color: AppColors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Text(
                '$shopsCount بقالات',
                style: const TextStyle(color: AppColors.white70, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (totals.isEmpty)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.white.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'ستظهر أرصدتك هنا بعد ربط حسابك بالمتاجر.',
                style: TextStyle(color: AppColors.white),
                textAlign: TextAlign.center,
              ),
            )
          else
            for (final total in totals.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: _BalanceTile(
                        label: 'عليك',
                        amount: format.format(total.value[0]),
                        currency: total.key,
                        icon: Icons.arrow_upward_rounded,
                        tint: const Color(0xFFFFD7D4),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: _BalanceTile(
                        label: 'لك',
                        amount: format.format(total.value[1]),
                        currency: total.key,
                        icon: Icons.arrow_downward_rounded,
                        tint: const Color(0xFFD3F5E5),
                      ),
                    ),
                  ],
                ),
              ),
          if (totals.length > 1)
            Text(
              'الأرصدة مفصولة حسب العملة',
              style: TextStyle(
                color: AppColors.white.withValues(alpha: .72),
                fontSize: 10,
              ),
              textAlign: TextAlign.center,
            ),
        ],
      ),
    );
  }
}

class _BalanceTile extends StatelessWidget {
  const _BalanceTile({
    required this.label,
    required this.amount,
    required this.currency,
    required this.icon,
    required this.tint,
  });

  final String label;
  final String amount;
  final String currency;
  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.white.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.white24),
      ),
      child: Row(
        children: [
          Icon(icon, color: tint, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.white70,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    '$amount $currency',
                    maxLines: 1,
                    style: TextStyle(
                      color: tint,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
