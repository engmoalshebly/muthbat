import '../../../../app/theme/app_typography.dart';
import 'package:flutter/material.dart';
import '../../../../app/theme/app_colors.dart';

const entryBlue = AppColors.primary;
const entryInk = AppColors.textPrimary;
const entryMint = AppColors.secondaryLight;

class EntryVisualTheme extends StatelessWidget {
  const EntryVisualTheme({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        colorScheme: base.colorScheme,
        scaffoldBackgroundColor: AppColors.backgroundLight,
        textTheme: base.textTheme.apply(
          bodyColor: entryInk,
          displayColor: entryInk,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: entryBlue,
            foregroundColor: AppColors.white,
            minimumSize: const Size.fromHeight(50),
            textStyle: const TextStyle(
              fontFamily: AppTypography.fontFamily,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: entryBlue),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            side: const WidgetStatePropertyAll(
              BorderSide(color: AppColors.segmentBorder),
            ),
            backgroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected)
                  ? entryBlue
                  : AppColors.white,
            ),
            foregroundColor: WidgetStateProperty.resolveWith(
              (s) =>
                  s.contains(WidgetState.selected) ? AppColors.white : entryInk,
            ),
          ),
        ),
      ),
      child: child,
    );
  }
}

class EntryBackdrop extends StatelessWidget {
  const EntryBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: [
          AppColors.entryBackgroundBlue,
          AppColors.entryBackgroundWhite,
          AppColors.entryBackgroundMint,
        ],
      ),
    ),
    child: Stack(
      children: [
        Positioned(top: -100, right: -90, child: _orb(260, AppColors.blueGlow)),
        Positioned(
          bottom: -100,
          left: -80,
          child: _orb(240, AppColors.mintGlow),
        ),
        Positioned.fill(child: child),
      ],
    ),
  );

  Widget _orb(double size, Color color) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color.withValues(alpha: .35),
    ),
  );
}
