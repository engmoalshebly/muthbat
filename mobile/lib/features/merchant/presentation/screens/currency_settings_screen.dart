import 'package:muthbat/shared/widgets/top_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/finance/currency_info.dart';
import '../../../../shared/widgets/custom_button.dart';
import '../controllers/merchant_controller.dart';

class CurrencySettingsScreen extends ConsumerStatefulWidget {
  const CurrencySettingsScreen({super.key});

  @override
  ConsumerState<CurrencySettingsScreen> createState() =>
      _CurrencySettingsScreenState();
}

class _CurrencySettingsScreenState
    extends ConsumerState<CurrencySettingsScreen> {
  late Set<String> _selected;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      final state = ref.read(merchantControllerProvider);
      _selected = state.supportedCurrencies
          .where((code) => code != state.currencyCode)
          .toSet();
      _initialized = true;
    }
  }

  Future<void> _save() async {
    final ok = await ref
        .read(merchantControllerProvider.notifier)
        .updateCurrencies(_selected.toList());
    if (!mounted) return;
    if (ok) {
      TopNotice.of(context).showSnackBar(
        const SnackBar(content: Text('تم تحديث العملات المفعلة بنجاح.')),
      );
      Navigator.pop(context);
    } else {
      final error =
          ref.read(merchantControllerProvider).lastError ??
          'تعذر تحديث العملات.';
      TopNotice.of(context).showSnackBar(
        SnackBar(content: Text(error), backgroundColor: AppColors.error),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(merchantControllerProvider);
    final base = CurrencyCatalog.forCode(state.currencyCode, state.currencies);
    final available = state.currencies.isEmpty
        ? CurrencyCatalog.defaults
        : state.currencies.where((currency) => currency.isActive).toList();

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(title: const Text('إدارة العملات')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.primaryContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'العملة الأساسية',
                  style: AppTypography.bodySmall(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${base.name} (${base.code})  ${base.symbol}',
                  style: AppTypography.titleMedium(
                    color: AppColors.primary,
                  ).copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  'العملة الأساسية ثابتة حفاظًا على سلامة الدفاتر السابقة.',
                  style: AppTypography.bodySmall(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'العملات الإضافية',
            style: AppTypography.titleMedium(
              color: AppColors.textPrimary,
            ).copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'فعّل العملات التي تريد استخدامها. لا يمكن تعطيل عملة لديها قيود مالية.',
            style: AppTypography.bodySmall(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          ...available
              .where((currency) => currency.code != state.currencyCode)
              .map(
                (currency) => Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: SwitchListTile(
                    value: _selected.contains(currency.code),
                    onChanged: state.isLoading
                        ? null
                        : (enabled) => setState(() {
                            if (enabled) {
                              _selected.add(currency.code);
                            } else {
                              _selected.remove(currency.code);
                            }
                          }),
                    title: Text(currency.name),
                    subtitle: Text(currency.code),
                    secondary: CircleAvatar(
                      backgroundColor: AppColors.primaryContainer,
                      child: Text(
                        currency.symbol,
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          const SizedBox(height: 14),
          CustomButton(
            text: 'حفظ العملات',
            isLoading: state.isLoading,
            onPressed: _save,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
