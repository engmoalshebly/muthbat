import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../auth/presentation/validators/auth_validators.dart';
import '../../data/models/business_customer_model.dart';
import '../controllers/merchant_controller.dart';

class AddCustomerScreen extends ConsumerStatefulWidget {
  const AddCustomerScreen({super.key});

  @override
  ConsumerState<AddCustomerScreen> createState() => _AddCustomerScreenState();
}

class _AddCustomerScreenState extends ConsumerState<AddCustomerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _limitController = TextEditingController();
  final _noteController = TextEditingController();

  bool _isSubmitting = false;
  bool _isPickingContact = false;
  String? _phoneError;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _limitController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  String _normalizePhoneForCompare(String raw) {
    final trimmed = raw.trim();
    var digits = AuthValidators.normalizeDigits(trimmed);
    if (trimmed.startsWith('00') && digits.length > 2) {
      digits = digits.substring(2);
    }
    if (trimmed.startsWith('+') || digits.startsWith('967')) {
      return '+$digits';
    }
    if (digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    return '+967$digits';
  }

  BusinessCustomerModel? _findLocalDuplicate(String rawPhone) {
    final normalized = _normalizePhoneForCompare(rawPhone);
    final customers = ref.read(merchantControllerProvider).customers;
    for (final customer in customers) {
      final phone = customer.phone;
      if (phone != null && _normalizePhoneForCompare(phone) == normalized) {
        return customer;
      }
    }
    return null;
  }

  Future<void> _pickFromContacts() async {
    if (_isPickingContact) return;
    FocusScope.of(context).unfocus();
    setState(() => _isPickingContact = true);

    try {
      final permission = await FlutterContacts.permissions.request(
        PermissionType.read,
      );
      if (permission != PermissionStatus.granted) {
        if (mounted) {
          _showMessage(
            'لم يتم السماح بالوصول إلى جهات الاتصال. يمكنك إدخال الرقم يدويًا.',
            isError: true,
          );
        }
        return;
      }

      final contact = await FlutterContacts.native.showPicker(
        properties: {ContactProperty.name, ContactProperty.phone},
      );
      if (!mounted || contact == null) return;

      final phone = contact.phones
          .map((item) => item.number.trim())
          .firstWhere((item) => item.isNotEmpty, orElse: () => '');
      if (phone.isEmpty) {
        _showMessage(
          'جهة الاتصال المحددة لا تحتوي على رقم هاتف.',
          isError: true,
        );
        return;
      }

      setState(() {
        if (_nameController.text.trim().isEmpty) {
          _nameController.text = contact.displayName?.trim() ?? '';
        }
        _phoneController.text = phone;
        _phoneError = null;
      });
    } catch (error) {
      if (mounted) {
        _showMessage(
          'تعذر فتح جهات الاتصال. يمكنك إدخال البيانات يدويًا.',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isPickingContact = false);
    }
  }

  Future<void> _handleSubmit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) return;

    final rawPhone = _phoneController.text.trim();
    if (rawPhone.isNotEmpty) {
      final existing = _findLocalDuplicate(rawPhone);
      if (existing != null) {
        setState(
          () => _phoneError =
              'هذا الرقم مسجل بالفعل باسم «${existing.localDisplayName}».',
        );
        return;
      }
    }

    setState(() => _isSubmitting = true);
    final phone = rawPhone.isEmpty ? null : rawPhone;
    final limitText = _limitController.text.trim();
    final limit = limitText.isEmpty ? null : double.tryParse(limitText);
    final note = _noteController.text.trim().isEmpty
        ? null
        : _noteController.text.trim();

    final customer = await ref
        .read(merchantControllerProvider.notifier)
        .addCustomer(
          name: _nameController.text.trim(),
          phone: phone,
          creditLimit: limit,
          note: note,
        );

    if (!mounted) return;
    setState(() => _isSubmitting = false);

    if (customer != null) {
      Navigator.pop<BusinessCustomerModel>(context, customer);
      return;
    }

    final dashboard = ref.read(merchantControllerProvider);
    if (dashboard.lastErrorCode == 'customer_exists') {
      setState(() => _phoneError = dashboard.lastError ?? 'الرقم مسجل مسبقًا.');
      return;
    }
    _showMessage(
      dashboard.lastError ?? 'تعذر إضافة العميل. حاول مرة أخرى.',
      isError: true,
    );
  }

  void _showMessage(String message, {required bool isError}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? AppColors.error : AppColors.success,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
  }

  InputDecoration _decoration({
    required String label,
    required IconData icon,
    String? hint,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      isDense: true,
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, color: AppColors.textSecondary, size: 21),
      suffixIcon: suffixIcon,
      filled: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.borderLight),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.borderLight),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.error, width: 1.4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final availableHeight =
        MediaQuery.of(context).size.height -
        MediaQuery.of(context).viewInsets.bottom;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 28),
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: availableHeight * 0.86,
        ),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'إغلاق',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                        color: AppColors.textSecondary,
                      ),
                      Expanded(
                        child: Text(
                          'إضافة عميل',
                          textAlign: TextAlign.center,
                          style: AppTypography.titleMedium(
                            color: AppColors.textPrimary,
                          ).copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                  Center(
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.person_add_alt_1_rounded,
                        color: AppColors.primary,
                        size: 27,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'عميل جديد',
                    textAlign: TextAlign.center,
                    style: AppTypography.titleMedium(
                      color: AppColors.textPrimary,
                    ).copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'أدخل البيانات الأساسية لفتح الحساب',
                    textAlign: TextAlign.center,
                    style: AppTypography.bodySmall(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _nameController,
                    textInputAction: TextInputAction.next,
                    decoration: _decoration(
                      label: 'اسم العميل *',
                      hint: 'مثال: محمد عبدالله',
                      icon: Icons.person_outline_rounded,
                    ),
                    validator: (value) => AuthValidators.nameError(value ?? ''),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) {
                      if (_phoneError != null) {
                        setState(() => _phoneError = null);
                      }
                    },
                    decoration: _decoration(
                      label: 'رقم الهاتف',
                      hint: '+967 7XX XXX XXX',
                      icon: Icons.phone_outlined,
                      suffixIcon: IconButton(
                        tooltip: 'اختيار من جهات الاتصال',
                        onPressed: _isPickingContact ? null : _pickFromContacts,
                        icon: _isPickingContact
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.contacts_outlined, size: 20),
                      ),
                    ).copyWith(errorText: _phoneError),
                    validator: (value) {
                      final raw = value?.trim() ?? '';
                      if (raw.isEmpty) return null;
                      try {
                        AuthValidators.normalizeE164(raw);
                        return null;
                      } catch (_) {
                        return 'أدخل رقم هاتف صحيحًا من 8 إلى 15 رقمًا';
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _limitController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textInputAction: TextInputAction.next,
                    decoration: _decoration(
                      label: 'الحد الائتماني (اختياري)',
                      hint: '0.0000',
                      icon: Icons.account_balance_wallet_outlined,
                    ),
                    validator: (value) {
                      final raw = value?.trim() ?? '';
                      if (raw.isEmpty) return null;
                      final amount = double.tryParse(raw);
                      if (amount == null || amount < 0) {
                        return 'أدخل مبلغًا صحيحًا غير سالب';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _noteController,
                    maxLines: 3,
                    textInputAction: TextInputAction.newline,
                    decoration: _decoration(
                      label: 'ملاحظة (اختيارية)',
                      hint: 'أضف ملاحظة تساعدك على تذكر تفاصيل الحساب',
                      icon: Icons.notes_rounded,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: _isSubmitting ? null : _handleSubmit,
                      icon: _isSubmitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.3,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check_circle_outline_rounded),
                      label: Text(
                        _isSubmitting
                            ? 'جاري حفظ العميل...'
                            : 'حفظ العميل وفتح الحساب',
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: AppColors.primary.withValues(
                          alpha: 0.7,
                        ),
                        textStyle: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
