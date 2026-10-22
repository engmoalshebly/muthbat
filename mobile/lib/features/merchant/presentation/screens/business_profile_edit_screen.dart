import 'package:image_picker/image_picker.dart';
import 'package:muthbat/shared/widgets/top_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/custom_button.dart';
import '../controllers/merchant_controller.dart';
import '../widgets/business_logo_avatar.dart';
import '../../data/merchant_api_exception.dart';

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

  bool _uploadingLogo = false;

  Future<void> _changeLogo() async {
    if (_uploadingLogo) return;
    setState(() => _uploadingLogo = true);
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 90,
        maxWidth: 1200,
        maxHeight: 1200,
      );
      if (image == null || !mounted) return;
      if (await image.length() > 5 * 1024 * 1024) {
        throw const MerchantApiException(
          code: 'invalid_logo_size',
          message: 'اختر صورة لا يتجاوز حجمها 5 ميجابايت.',
        );
      }
      final bytes = await image.readAsBytes();
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('معاينة شعار المتجر'),
          content: SizedBox(
            width: 220,
            height: 220,
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) =>
                  const Center(child: Text('تعذر عرض الصورة')),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('اعتماد الشعار'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final ok = await ref
          .read(merchantControllerProvider.notifier)
          .updateBusinessLogo(
            bytes: bytes,
            extension: image.name.split('.').last,
          );
      if (!mounted) return;
      TopNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'تم حفظ الشعار، وستتم مزامنته تلقائياً.'
                : ref.read(merchantControllerProvider).lastError ??
                      'تعذر تحديث الشعار.',
          ),
          backgroundColor: ok ? AppColors.success : AppColors.error,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      TopNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is MerchantApiException
                ? error.message
                : 'تعذر اختيار الشعار. حاول مرة أخرى.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _uploadingLogo = false);
    }
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
    final business = ref.watch(merchantControllerProvider);
    final logoPending =
        business.businessLogoSyncStatus != null &&
        business.businessLogoSyncStatus != 'dead_letter';
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        title: const Text('بيانات المتجر'),
        backgroundColor: AppColors.white,
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
                gradient: AppColors.cardGradient,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                children: [
                  BusinessLogoAvatar(
                    name: business.businessName,
                    path: business.businessLogoPath,
                    preview: business.businessLogoPreview,
                    size: 64,
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'هوية منشأتك',
                          style: TextStyle(
                            color: AppColors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'تظهر هذه البيانات في كشوف الحساب وملفات PDF.',
                          style: TextStyle(
                            color: AppColors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _sectionTitle('البيانات الأساسية'),
            OutlinedButton.icon(
              onPressed:
                  _uploadingLogo ||
                      _saving ||
                      logoPending ||
                      !business.isBusinessOwner
                  ? null
                  : _changeLogo,
              icon: const Icon(Icons.image_outlined),
              label: Text(
                _uploadingLogo ? 'جاري حفظ الشعار...' : 'تغيير شعار المتجر',
              ),
            ),
            if (_uploadingLogo) const LinearProgressIndicator(),
            Text(
              logoPending
                  ? 'الشعار محفوظ على الجهاز، وبانتظار اكتمال المزامنة.'
                  : 'اختر صورة واضحة حتى 5 ميجابايت. يُحفظ الشعار منفصلًا عن بيانات المتجر.',
              style: AppTypography.bodySmall(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
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
              items: [
                const DropdownMenuItem(value: 'YE', child: Text('اليمن')),
                const DropdownMenuItem(value: 'SA', child: Text('السعودية')),
                if (!{'YE', 'SA'}.contains(_country))
                  DropdownMenuItem(value: _country, child: Text(_country)),
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
              items: [
                const DropdownMenuItem(
                  value: 'Asia/Aden',
                  child: Text('توقيت عدن (GMT+3)'),
                ),
                const DropdownMenuItem(
                  value: 'Asia/Riyadh',
                  child: Text('توقيت الرياض (GMT+3)'),
                ),
                if (!{'Asia/Aden', 'Asia/Riyadh'}.contains(_timezone))
                  DropdownMenuItem(value: _timezone, child: Text(_timezone)),
              ],
              onChanged: (value) =>
                  setState(() => _timezone = value ?? 'Asia/Aden'),
            ),
            const SizedBox(height: 24),
            CustomButton(
              text: _saving ? 'جاري الحفظ...' : 'حفظ التغييرات',
              onPressed: _saving || _uploadingLogo || !business.isBusinessOwner
                  ? null
                  : _save,
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
    fillColor: AppColors.white,
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
