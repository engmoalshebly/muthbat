import '../../../../app/theme/app_colors.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../auth/presentation/widgets/entry_visual_theme.dart';

/// Resolution-independent artwork; all content here is illustrative.
class WelcomeIllustration extends StatelessWidget {
  const WelcomeIllustration({super.key, required this.step});
  final int step;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: [
      'دفتر حسابات منظم',
      'تسجيل الديون والدفعات',
      'دفتر محلي وحساب سحابي',
    ][step],
    child: ExcludeSemantics(
      child: SizedBox(
        height: 270,
        width: 310,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 244,
              height: 244,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.illustrationHalo,
                    AppColors.illustrationHalo.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
            Positioned(top: 10, left: 18, child: _spark(entryMint, 15)),
            Positioned(
              bottom: 23,
              right: 13,
              child: _spark(AppColors.illustrationApricot, 21),
            ),
            Transform.rotate(
              angle: -.07,
              child: Container(
                width: 178,
                height: 214,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppColors.primaryLight,
                      entryBlue,
                      AppColors.illustrationBlueDeep,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: entryBlue.withValues(alpha: .25),
                      blurRadius: 32,
                      offset: const Offset(0, 20),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(17),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.auto_stories_rounded,
                            color: AppColors.white,
                            size: 23,
                          ),
                          const Spacer(),
                          Container(
                            width: 32,
                            height: 5,
                            decoration: BoxDecoration(
                              color: AppColors.white54,
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      if (step == 0) ...[
                        const Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            'دفترك، بوضوح',
                            style: TextStyle(
                              color: AppColors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _line(118),
                        const SizedBox(height: 10),
                        _line(90),
                        const SizedBox(height: 10),
                        _line(106),
                      ] else if (step == 1) ...[
                        _record(Icons.south_west_rounded, entryMint, 'دفعة'),
                        const SizedBox(height: 10),
                        _record(
                          Icons.north_east_rounded,
                          AppColors.illustrationPeach,
                          'دين',
                        ),
                      ] else ...[
                        Container(
                          padding: const EdgeInsets.all(13),
                          decoration: BoxDecoration(
                            color: AppColors.white.withValues(alpha: .16),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Icon(
                            Icons.phonelink_lock_rounded,
                            color: AppColors.white,
                            size: 48,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'على جهازك… ومعك',
                          style: TextStyle(
                            color: AppColors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              right: 1,
              top: 39,
              child: Transform.rotate(
                angle: .09,
                child: _badge(
                  step == 2 ? Icons.cloud_outlined : Icons.check_rounded,
                  step == 2 ? 'حسابك' : 'مُثبَت',
                  AppColors.white,
                  entryBlue,
                ),
              ),
            ),
            Positioned(
              left: 2,
              bottom: 28,
              child: Transform.rotate(
                angle: -.04,
                child: _badge(
                  step == 1 ? Icons.add_rounded : Icons.shield_outlined,
                  step == 1
                      ? 'حركة جديدة'
                      : step == 2
                      ? 'بدون حساب'
                      : 'كل حق محفوظ',
                  AppColors.secondaryContainer,
                  AppColors.illustrationGreenInk,
                ),
              ),
            ),
            Positioned(
              right: 34,
              bottom: 9,
              child: Container(
                width: 37,
                height: 37,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [
                      AppColors.illustrationGoldLight,
                      AppColors.illustrationGold,
                    ],
                  ),
                  border: Border.all(
                    color: AppColors.illustrationGoldBorder,
                    width: 4,
                  ),
                ),
                child: const Icon(
                  Icons.star_rounded,
                  color: AppColors.illustrationGoldInk,
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _spark(Color color, double size) => Transform.rotate(
    angle: math.pi / 4,
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
    ),
  );
  Widget _line(double width) => Align(
    alignment: Alignment.centerRight,
    child: Container(
      width: width,
      height: 8,
      decoration: BoxDecoration(
        color: AppColors.white.withValues(alpha: .65),
        borderRadius: BorderRadius.circular(8),
      ),
    ),
  );
  Widget _record(IconData icon, Color color, String text) => Container(
    padding: const EdgeInsets.all(9),
    decoration: BoxDecoration(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Icon(icon, color: color, size: 21),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(color: entryInk, fontWeight: FontWeight.bold),
        ),
        const Spacer(),
        Container(width: 24, height: 5, color: AppColors.illustrationLine),
      ],
    ),
  );
  Widget _badge(
    IconData icon,
    String label,
    Color background,
    Color foreground,
  ) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(17),
      boxShadow: [
        BoxShadow(
          color: entryInk.withValues(alpha: .08),
          blurRadius: 20,
          offset: const Offset(0, 8),
        ),
      ],
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: foreground, size: 21),
        const SizedBox(width: 7),
        Text(
          label,
          style: TextStyle(
            color: foreground,
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
      ],
    ),
  );
}
