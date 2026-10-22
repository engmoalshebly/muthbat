import '../../../auth/presentation/widgets/compact_auth_layout.dart';
import 'package:muthbat/shared/widgets/top_notice.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../core/finance/currency_info.dart';
import '../controllers/merchant_controller.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';

/// شاشة معالج إعداد المنشأة لأول مرة (First-Time Business Setup Wizard)
class BusinessSetupScreen extends ConsumerStatefulWidget {
  const BusinessSetupScreen({super.key});

  @override
  ConsumerState<BusinessSetupScreen> createState() =>
      _BusinessSetupScreenState();
}

class _BusinessSetupScreenState extends ConsumerState<BusinessSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _cityController = TextEditingController(text: 'صنعاء');
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController();

  String _selectedType = 'تجارة تجزئة وبقالة';
  String _selectedCurrency = 'YER';
  final Set<String> _additionalCurrencies = <String>{};
  bool _isSubmitting = false;

  final List<String> _businessTypes = [
    'تجارة تجزئة وبقالة',
    'تجارة جملة وتوزيع',
    'مواد بناء وكهرباء',
    'صيدلية وأدوية',
    'ملابس وأقمشة',
    'إلكترونيات وهواتف',
    'مقاولات وخدمات عامة',
    'أخرى',
  ];

  final List<CurrencyInfo> _currencies = CurrencyCatalog.defaults
      .where((currency) => const {'YER', 'SAR', 'USD'}.contains(currency.code))
      .toList();

  @override
  void initState() {
    super.initState();
    final account = ref.read(authControllerProvider);
    _nameController.text = account.displayName ?? '';
    _phoneController.text = account.phoneNumber ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _cityController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    if (_isSubmitting) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);

    final success = await ref
        .read(merchantControllerProvider.notifier)
        .createBusiness(
          name: _nameController.text.trim(),
          businessType: _selectedType,
          currencyCode: _selectedCurrency,
          additionalCurrencies: _additionalCurrencies.toList(),
          city: _cityController.text.trim(),
          address: _addressController.text.trim().isNotEmpty
              ? _addressController.text.trim()
              : null,
          contactPhoneDisplay: _phoneController.text.trim().isNotEmpty
              ? _phoneController.text.trim()
              : null,
        );

    if (!mounted) return;
    setState(() => _isSubmitting = false);

    if (success && mounted) {
      await ref
          .read(authControllerProvider.notifier)
          .refreshLocalBusinessAccess();
      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(
        context,
        AppRoutes.merchantHome,
        (route) => false,
      );
    } else if (mounted) {
      final error =
          ref.read(merchantControllerProvider).lastError ??
          'تعذر إنشاء المنشأة. يرجى المحاولة مجدداً.';
      TopNotice.of(context).showSnackBar(
        SnackBar(content: Text(error), backgroundColor: AppColors.error),
      );
    }
  }

  @override
  Widget build(BuildContext context) => CompactAuthLayout(
    title: 'خطوة أخيرة لمنشأتك',
    subtitle:
        'حفظنا الاسم ورقم الهاتف من حسابك. يمكنك إضافة الشعار والعنوان لاحقًا من الإعدادات.',
    children: [
      Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _nameController,
              enabled: !_isSubmitting,
              textInputAction: TextInputAction.next,
              decoration: compactAuthDecoration('اسم المنشأة'),
              validator: (v) =>
                  v == null || v.trim().length < 2 ? 'أدخل اسم المنشأة' : null,
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _selectedType,
              isExpanded: true,
              decoration: compactAuthDecoration('نوع النشاط'),
              items: _businessTypes
                  .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                  .toList(),
              onChanged: _isSubmitting
                  ? null
                  : (v) => setState(() => _selectedType = v!),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _selectedCurrency,
              decoration: compactAuthDecoration('العملة الأساسية'),
              items: _currencies
                  .map(
                    (v) => DropdownMenuItem(value: v.code, child: Text(v.code)),
                  )
                  .toList(),
              onChanged: _isSubmitting
                  ? null
                  : (v) => setState(() => _selectedCurrency = v!),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _isSubmitting ? null : _handleSubmit,
              child: Text(_isSubmitting ? 'جارٍ الإعداد…' : 'ابدأ الاستخدام'),
            ),
          ],
        ),
      ),
    ],
  );
}
