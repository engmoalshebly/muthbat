import 'package:muthbat/shared/widgets/top_notice.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/brand_logo.dart';
import '../../../../shared/widgets/custom_button.dart';
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
  XFile? _logo;

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
  void dispose() {
    _nameController.dispose();
    _cityController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);

    final logoBytes = await _logo?.readAsBytes();
    final logoExtension = _logo?.name.split('.').last.toLowerCase() ?? 'jpg';
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
          logoBytes: logoBytes,
          logoExtension: logoExtension,
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: SingleChildScrollView(
        child: Column(
          children: [
            // ترويسة علوية فاخرة
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(24, 60, 24, 30),
              decoration: const BoxDecoration(
                gradient: AppColors.brandGradient,
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(36),
                ),
              ),
              child: Column(
                children: [
                  const BrandLogo.icon(width: 54, height: 54).animate().scale(
                    duration: 400.ms,
                    curve: Curves.easeOutBack,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'إعداد منشأتك التجارية',
                    style: AppTypography.titleLarge(
                      color: Colors.white,
                    ).copyWith(fontSize: 24, fontWeight: FontWeight.w800),
                    textAlign: TextAlign.center,
                  ).animate().fadeIn().slideY(begin: 0.2, end: 0),
                  const SizedBox(height: 6),
                  Text(
                    'أدخل بيانات محلك لبدء توثيق الديون والمبيعات بأمان',
                    style: AppTypography.bodySmall(
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                    textAlign: TextAlign.center,
                  ).animate().fadeIn(delay: 150.ms),
                ],
              ),
            ),

            // استمارة البيانات
            Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'شعار المنشأة (اختياري)',
                      style: AppTypography.bodyLarge().copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () async {
                        final picked = await ImagePicker().pickImage(
                          source: ImageSource.gallery,
                          imageQuality: 88,
                          maxWidth: 1200,
                          maxHeight: 1200,
                        );
                        if (picked != null && mounted) {
                          setState(() => _logo = picked);
                        }
                      },
                      child: Container(
                        height: 112,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: _logo == null
                            ? const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.add_photo_alternate_outlined,
                                    color: AppColors.primary,
                                    size: 32,
                                  ),
                                  SizedBox(height: 6),
                                  Text('اضغط لاختيار الشعار من الصور'),
                                ],
                              )
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(17),
                                child: Image.file(
                                  File(_logo!.path),
                                  fit: BoxFit.contain,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // اسم المنشأة
                    Text(
                      'اسم المنشأة / المحل التجارية',
                      style: AppTypography.bodyLarge().copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _nameController,
                      textDirection: TextDirection.rtl,
                      decoration: InputDecoration(
                        hintText: 'مثال: تموينات البركة، مؤسسة النور...',
                        prefixIcon: const Icon(
                          AppIcons.store,
                          color: AppColors.primary,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: Colors.grey.shade200),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: Colors.grey.shade200),
                        ),
                      ),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'يرجى إدخال اسم المحل أو المنشأة';
                        }
                        if (val.trim().length < 3) {
                          return 'يجب أن يكون الاسم 3 أحرف على الأقل';
                        }
                        return null;
                      },
                    ),

                    const SizedBox(height: 20),

                    // نوع النشاط
                    Text(
                      'نوع النشاط التجاري',
                      style: AppTypography.bodyLarge().copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _selectedType,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(
                          AppIcons.reports,
                          color: AppColors.primary,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: Colors.grey.shade200),
                        ),
                      ),
                      items: _businessTypes
                          .map(
                            (type) => DropdownMenuItem(
                              value: type,
                              child: Text(
                                type,
                                style: AppTypography.bodyMedium(),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (val) {
                        if (val != null) setState(() => _selectedType = val);
                      },
                    ),

                    const SizedBox(height: 20),

                    // العملة الافتراضية
                    Text(
                      'العملة الافتراضية للدفتر',
                      style: AppTypography.bodyLarge().copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: _currencies.map((curr) {
                        final isSelected = _selectedCurrency == curr.code;
                        return Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() {
                              _selectedCurrency = curr.code;
                              _additionalCurrencies.remove(_selectedCurrency);
                            }),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? AppColors.primary
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isSelected
                                      ? AppColors.primary
                                      : Colors.grey.shade200,
                                  width: isSelected ? 2 : 1,
                                ),
                                boxShadow: isSelected
                                    ? [
                                        BoxShadow(
                                          color: AppColors.primary.withValues(
                                            alpha: 0.25,
                                          ),
                                          blurRadius: 8,
                                          offset: const Offset(0, 4),
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    curr.symbol,
                                    style: TextStyle(
                                      color: isSelected
                                          ? Colors.white
                                          : AppColors.primary,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    curr.name,
                                    style: TextStyle(
                                      color: isSelected
                                          ? Colors.white
                                          : AppColors.textSecondary,
                                      fontSize: 11,
                                      fontWeight: isSelected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),

                    const SizedBox(height: 18),
                    Text(
                      'عملات إضافية اختيارية',
                      style: AppTypography.bodyLarge().copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'تظهر كل عملة في رصيد مستقل بدون تحويل أو جمع بينها.',
                      style: AppTypography.bodySmall(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: _currencies
                          .where((curr) => curr.code != _selectedCurrency)
                          .map((curr) {
                            final code = curr.code;
                            return FilterChip(
                              label: Text(code),
                              selected: _additionalCurrencies.contains(code),
                              onSelected: (selected) => setState(() {
                                if (selected) {
                                  _additionalCurrencies.add(code);
                                } else {
                                  _additionalCurrencies.remove(code);
                                }
                              }),
                            );
                          })
                          .toList(),
                    ),

                    const SizedBox(height: 20),

                    Text(
                      'رقم تواصل المنشأة',
                      style: AppTypography.bodyLarge().copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      textDirection: TextDirection.ltr,
                      decoration: InputDecoration(
                        hintText: '+967 7XX XXX XXX',
                        prefixIcon: const Icon(
                          Icons.phone_outlined,
                          color: AppColors.primary,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    Text(
                      'العنوان التفصيلي',
                      style: AppTypography.bodyLarge().copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _addressController,
                      textDirection: TextDirection.rtl,
                      decoration: InputDecoration(
                        hintText: 'الحي، الشارع، أقرب معلم',
                        prefixIcon: const Icon(
                          Icons.location_on_outlined,
                          color: AppColors.primary,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // المدينة
                    Text(
                      'المدينة / المنطقة',
                      style: AppTypography.bodyLarge().copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _cityController,
                      textDirection: TextDirection.rtl,
                      decoration: InputDecoration(
                        hintText: 'مثال: صنعاء، عدن، تعز...',
                        prefixIcon: const Icon(
                          AppIcons.store,
                          color: AppColors.primary,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: Colors.grey.shade200),
                        ),
                      ),
                    ),

                    const SizedBox(height: 32),

                    // زر الإنشاء والمتابعة
                    CustomButton(
                          text: 'حفظ وبدء الاستخدام',
                          isLoading: _isSubmitting,
                          onPressed: _handleSubmit,
                        )
                        .animate()
                        .fadeIn(delay: 200.ms)
                        .slideY(begin: 0.1, end: 0),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
