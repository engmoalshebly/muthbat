import 'package:muthbat/shared/widgets/top_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/custom_button.dart';
import '../controllers/merchant_controller.dart';

class BusinessProfileEditScreen extends ConsumerStatefulWidget {
  const BusinessProfileEditScreen({super.key});

  @override
  ConsumerState<BusinessProfileEditScreen> createState() =>
      _BusinessProfileEditScreenState();
}

class _BusinessProfileEditScreenState
    extends ConsumerState<BusinessProfileEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _type;
  late final TextEditingController _city;
  late final TextEditingController _address;
  late final TextEditingController _phone;
  String _country = 'YE';
  String _timezone = 'Asia/Aden';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final state = ref.read(merchantControllerProvider);
    _name = TextEditingController(text: state.businessName);
    _type = TextEditingController(text: state.businessType);
    _city = TextEditingController(text: state.businessCity);
    _address = TextEditingController(text: state.businessAddress);
    _phone = TextEditingController(text: state.businessContactPhone);
    _country = state.businessCountryCode;
    _timezone = state.businessTimezone;
  }

  @override
  void dispose() {
    _name.dispose();
    _type.dispose();
    _city.dispose();
    _address.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _saving) return;
    setState(() => _saving = true);
    final ok = await ref
        .read(merchantControllerProvider.notifier)
        .updateBusinessProfile(
          name: _name.text,
          businessType: _type.text,
          countryCode: _country,
          city: _city.text,
          address: _address.text,
          contactPhone: _phone.text,
          timezone: _timezone,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    final error = ref.read(merchantControllerProvider).lastError;
    TopNotice.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'تم حفظ ملف المنشأة، وستتم مزامنته تلقائياً.'
              : error ?? 'تعذر حفظ بيانات المنشأة.',
        ),
        backgroundColor: ok ? AppColors.success : AppColors.error,
      ),
    );
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        title: const Text('ملف المنشأة'),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: AppColors.brandGradient,
                borderRadius: BorderRadius.circular(22),
              ),
              child: const Row(
                children: [
                  CircleAvatar(
                    radius: 25,
                    backgroundColor: Colors.white24,
                    child: Icon(AppIcons.store, color: Colors.white, size: 26),
                  ),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'هوية منشأتك',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'تظهر هذه البيانات في كشوف الحساب وملفات PDF.',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _sectionTitle('البيانات الأساسية'),
            _field(
              controller: _name,
              label: 'اسم المنشأة',
              icon: AppIcons.store,
              required: true,
            ),
            _field(
              controller: _type,
              label: 'النشاط التجاري',
              hint: 'مثال: تجارة تجزئة ومواد غذائية',
              icon: AppIcons.reports,
              required: true,
            ),
            const SizedBox(height: 8),
            _sectionTitle('العنوان والتواصل'),
            DropdownButtonFormField<String>(
              initialValue: _country,
              decoration: _decoration('الدولة', Icons.public_rounded),
              items: const [
                DropdownMenuItem(value: 'YE', child: Text('اليمن')),
                DropdownMenuItem(value: 'SA', child: Text('السعودية')),
              ],
              onChanged: (value) => setState(() => _country = value ?? 'YE'),
            ),
            const SizedBox(height: 12),
            _field(
              controller: _city,
              label: 'المدينة',
              icon: Icons.location_city_rounded,
            ),
            _field(
              controller: _address,
              label: 'العنوان التفصيلي',
              icon: Icons.location_on_outlined,
              maxLines: 2,
            ),
            _field(
              controller: _phone,
              label: 'رقم تواصل المنشأة',
              icon: Icons.phone_outlined,
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 8),
            _sectionTitle('التوقيت والمستندات'),
            DropdownButtonFormField<String>(
              initialValue: _timezone,
              decoration: _decoration('المنطقة الزمنية', Icons.schedule),
              items: const [
                DropdownMenuItem(
                  value: 'Asia/Aden',
                  child: Text('توقيت عدن (GMT+3)'),
                ),
                DropdownMenuItem(
                  value: 'Asia/Riyadh',
                  child: Text('توقيت الرياض (GMT+3)'),
                ),
              ],
              onChanged: (value) =>
                  setState(() => _timezone = value ?? 'Asia/Aden'),
            ),
            const SizedBox(height: 24),
            CustomButton(
              text: _saving ? 'جاري الحفظ...' : 'حفظ ملف المنشأة',
              onPressed: _saving ? null : _save,
              icon: Icons.save_outlined,
            ),
            const SizedBox(height: 12),
            Text(
              'يُحفظ التعديل على الجهاز فوراً، ثم تتم مزامنته مع الخادم عند توفر الإنترنت.',
              textAlign: TextAlign.center,
              style: AppTypography.bodySmall(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      title,
      style: AppTypography.titleSmall(
        color: AppColors.textPrimary,
      ).copyWith(fontWeight: FontWeight.w800),
    ),
  );

  InputDecoration _decoration(String label, IconData icon) => InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon, size: 20),
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: AppColors.borderLight),
    ),
  );

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    bool required = false,
    int maxLines = 1,
    TextInputType? keyboardType,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: _decoration(label, icon).copyWith(hintText: hint),
      validator: required
          ? (value) => value == null || value.trim().length < 2
                ? 'يرجى إدخال $label بشكل صحيح'
                : null
          : null,
    ),
  );
}
