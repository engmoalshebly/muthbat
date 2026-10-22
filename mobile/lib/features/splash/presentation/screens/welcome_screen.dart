import '../../../auth/presentation/widgets/entry_visual_theme.dart';
import '../widgets/welcome_illustration.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});
  static const completedKey = 'welcome_completed_v1';

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _pages = PageController();
  int _step = 0;
  bool _choosing = false;
  bool _busy = false;
  static const _slides = [
    (
      Icons.auto_stories_outlined,
      'كل حق… مُثبَت',
      'دفتر بسيط يجمع حساباتك، لتعرف ما لك وما عليك بوضوح.',
    ),
    (
      Icons.receipt_long_outlined,
      'سجّلها في لحظتها',
      'أضف العملاء وسجّل الديون والدفعات، وتابع الحركة من مكان واحد.',
    ),
    (
      Icons.phonelink_lock_outlined,
      'ابدأ بالطريقة التي تناسبك',
      'استخدم دفتر جهازك دون حساب، أو أنشئ حساب متجر أو زبون للخدمات المرتبطة بالحساب.',
    ),
  ];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _choose(String role) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool(WelcomeScreen.completedKey, true)) {
        throw StateError('Unable to save welcome preference');
      }
      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(
        context,
        role == 'local' ? AppRoutes.localLedger : AppRoutes.register,
        (_) => false,
        arguments: role == 'customer' ? 'customer' : 'merchant',
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر حفظ اختيارك. حاول مجددًا.')),
      );
    }
  }

  Widget _role(IconData icon, String title, String subtitle, String role) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Card(
          margin: EdgeInsets.zero,
          color: AppColors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: AppColors.choiceBorder),
          ),
          child: ListTile(
            enabled: !_busy,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 10,
            ),
            leading: CircleAvatar(
              backgroundColor: role == 'merchant'
                  ? AppColors.badgeRefBg
                  : role == 'customer'
                  ? AppColors.secondaryContainer
                  : AppColors.roleLocalSurface,
              child: Icon(
                icon,
                color: role == 'merchant'
                    ? entryBlue
                    : role == 'customer'
                    ? AppColors.roleCustomerInk
                    : AppColors.roleLocalInk,
              ),
            ),
            title: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(subtitle),
            trailing: const Icon(Icons.chevron_left),
            onTap: () => _choose(role),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => EntryVisualTheme(
    child: Scaffold(
      backgroundColor: AppColors.transparent,
      body: EntryBackdrop(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Text(
                      'مُثبَت',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.bold,
                        color: entryInk,
                      ),
                    ),
                    const Spacer(),
                    if (!_choosing)
                      TextButton(
                        onPressed: () => setState(() => _choosing = true),
                        child: const Text('تخطي المقدمة'),
                      ),
                  ],
                ),
                Expanded(
                  child: _choosing
                      ? SingleChildScrollView(
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 440),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const SizedBox(height: 28),
                                  const Text(
                                    'كيف تحب تستخدم مُثبَت؟',
                                    style: TextStyle(
                                      fontSize: 25,
                                      fontWeight: FontWeight.bold,
                                      color: entryInk,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    'اختر ما يناسبك الآن. يمكنك إنشاء حساب لاحقًا من دفتر الجهاز.',
                                  ),
                                  const SizedBox(height: 24),
                                  _role(
                                    Icons.storefront_outlined,
                                    'صاحب متجر',
                                    'إنشاء حساب متجر وتنظيم حسابات العملاء',
                                    'merchant',
                                  ),
                                  _role(
                                    Icons.person_outline,
                                    'زبون',
                                    'إنشاء حساب زبون ومتابعة حساباتك المرتبطة',
                                    'customer',
                                  ),
                                  _role(
                                    Icons.edit_note_outlined,
                                    'مستخدم عادي',
                                    'دفتر على جهازك · بدون تسجيل أو حساب',
                                    'local',
                                  ),
                                  if (_busy)
                                    const Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => Navigator.pushNamed(
                                            context,
                                            AppRoutes.login,
                                          ),
                                    child: const Text(
                                      'لديك حساب بالفعل؟ تسجيل الدخول',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      : PageView.builder(
                          controller: _pages,
                          itemCount: _slides.length,
                          onPageChanged: (v) => setState(() => _step = v),
                          itemBuilder: (context, index) {
                            final slide = _slides[index];
                            return LayoutBuilder(
                              builder: (context, size) => SingleChildScrollView(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: size.maxHeight,
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      WelcomeIllustration(step: index),
                                      const SizedBox(height: 32),
                                      Text(
                                        slide.$2,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 27,
                                          fontWeight: FontWeight.bold,
                                          color: entryInk,
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        slide.$3,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          height: 1.7,
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                if (!_choosing) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      3,
                      (i) => AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.all(4),
                        width: i == _step ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: i == _step ? entryBlue : AppColors.borderLight,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () {
                      if (_step == 2) {
                        setState(() => _choosing = true);
                      } else {
                        _pages.nextPage(
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOut,
                        );
                      }
                    },
                    child: Text(_step == 2 ? 'اختر طريقة الاستخدام' : 'التالي'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
