import 'package:flutter/material.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';

class CountryInfo {
  final String name;
  final String dialCode;
  final String flag;
  final String code;

  const CountryInfo({
    required this.name,
    required this.dialCode,
    required this.flag,
    required this.code,
  });
}

const List<CountryInfo> supportedCountries = [
  CountryInfo(name: 'اليمن', dialCode: '+967', flag: '🇾🇪', code: 'YE'),
  CountryInfo(name: 'السعودية', dialCode: '+966', flag: '🇸🇦', code: 'SA'),
  CountryInfo(name: 'مصر', dialCode: '+20', flag: '🇪🇬', code: 'EG'),
  CountryInfo(name: 'الإمارات', dialCode: '+971', flag: '🇦🇪', code: 'AE'),
  CountryInfo(name: 'عُمان', dialCode: '+968', flag: '🇴🇲', code: 'OM'),
  CountryInfo(name: 'الكويت', dialCode: '+965', flag: '🇰🇼', code: 'KW'),
  CountryInfo(name: 'قطر', dialCode: '+974', flag: '🇶🇦', code: 'QA'),
  CountryInfo(name: 'البحرين', dialCode: '+973', flag: '🇧🇭', code: 'BH'),
  CountryInfo(name: 'الأردن', dialCode: '+962', flag: '🇯🇴', code: 'JO'),
  CountryInfo(name: 'العراق', dialCode: '+964', flag: '🇮🇶', code: 'IQ'),
];

/// زر منبثق لاختيار مفتاح الدولة
class CountryCodePickerButton extends StatelessWidget {
  final CountryInfo selectedCountry;
  final ValueChanged<CountryInfo> onSelected;

  const CountryCodePickerButton({
    super.key,
    required this.selectedCountry,
    required this.onSelected,
  });

  void _showPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.borderLight,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    'اختر الدولة / رمز الاتصال',
                    style: AppTypography.titleMedium(color: AppColors.primary),
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: supportedCountries.length,
                    separatorBuilder: (context, index) => const Divider(height: 1, color: AppColors.borderLight),
                    itemBuilder: (context, index) {
                      final country = supportedCountries[index];
                      final isSelected = country.dialCode == selectedCountry.dialCode;

                      return ListTile(
                        onTap: () {
                          onSelected(country);
                          Navigator.pop(ctx);
                        },
                        leading: Text(
                          country.flag,
                          style: const TextStyle(fontSize: 26),
                        ),
                        title: Text(
                          country.name,
                          style: AppTypography.bodyLarge(
                            color: isSelected ? AppColors.secondary : AppColors.textPrimary,
                          ).copyWith(fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500),
                        ),
                        trailing: Text(
                          country.dialCode,
                          textDirection: TextDirection.ltr,
                          style: AppTypography.financialAmount(
                            fontSize: 15,
                            color: isSelected ? AppColors.secondary : AppColors.textSecondary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _showPicker(context),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.primaryContainer.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              selectedCountry.flag,
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(width: 6),
            Text(
              selectedCountry.dialCode,
              textDirection: TextDirection.ltr,
              style: AppTypography.financialAmount(
                fontSize: 14,
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
