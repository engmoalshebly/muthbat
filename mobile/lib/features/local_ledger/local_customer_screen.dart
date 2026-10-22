import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_icons.dart';
import 'local_ledger_store.dart';

class LocalCustomerScreen extends StatefulWidget {
  const LocalCustomerScreen({super.key, required this.store});
  final LocalLedgerStore store;

  @override
  State<LocalCustomerScreen> createState() => _LocalCustomerScreenState();
}

class _LocalCustomerScreenState extends State<LocalCustomerScreen> {
  final name = TextEditingController();
  final phone = TextEditingController();
  final description = TextEditingController();
  bool saving = false;
  String? error;

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    description.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving) return;
    FocusScope.of(context).unfocus();
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final id = await widget.store.addCustomer(
        name.text,
        phone: phone.text,
        description: description.text,
      );
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        saving = false;
        error = e is FormatException
            ? e.message
            : e is StateError
            ? e.message.toString()
            : 'تعذر حفظ العميل. حاول مجددًا.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        title: const Text('إضافة عميل'),
        leading: IconButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          tooltip: 'رجوع',
          icon: const Icon(AppIcons.chevronStart),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(AppIcons.customers, color: AppColors.primary),
                  title: Text('حساب جديد لعميلك'),
                  subtitle: Text('احفظ العميل الآن وأضف عملياته لاحقًا.'),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: name,
                  enabled: !saving,
                  autofocus: true,
                  maxLength: 120,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'اسم العميل',
                    hintText: 'اكتب الاسم الكامل',
                    prefixIcon: const Icon(AppIcons.singleCustomer, size: 20),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phone,
                  enabled: !saving,
                  keyboardType: TextInputType.phone,
                  textDirection: TextDirection.ltr,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'رقم الهاتف *',
                    helperText: 'يساعدك في العثور على العميل عند تسجيل عملية.',
                    prefixIcon: Icon(AppIcons.phone, size: 20),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: description,
                  enabled: !saving,
                  maxLength: 500,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'وصف العميل (اختياري)',
                    hintText: 'مثلاً: عنوان العميل أو ملاحظة عنه',
                    prefixIcon: Icon(AppIcons.receipt, size: 20),
                  ),
                ),
                const SizedBox(height: 20),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      error!,
                      style: const TextStyle(color: AppColors.error),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: saving ? null : save,
                  icon: saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.white,
                          ),
                        )
                      : const Icon(AppIcons.check, size: 18),
                  label: Text(saving ? 'جارٍ الحفظ…' : 'حفظ العميل'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
