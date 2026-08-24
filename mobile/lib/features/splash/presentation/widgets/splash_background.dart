import 'package:flutter/material.dart';
import '../../../../app/theme/app_colors.dart';

/// خلفية شاشة البداية ذات التدرج اللوني والوهج الرقمي المحاسبي
class SplashBackground extends StatelessWidget {
  final Widget child;

  const SplashBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 1. التدرج الأساسي العميق
        Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: AppColors.splashGradient,
          ),
        ),

        // 2. وهج علوي أزرق بترولي (Top-Right Ambient Glow)
        Positioned(
          top: -100,
          right: -80,
          child: Container(
            width: 320,
            height: 320,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.secondary.withValues(alpha: 0.22),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),

        // 3. وهج ذهبي دافئ خافت بالأسفل (Bottom-Left Subtle Gold Glow)
        Positioned(
          bottom: -80,
          left: -60,
          child: Container(
            width: 280,
            height: 280,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.accentGold.withValues(alpha: 0.12),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),

        // 4. خطوط الشبكة الهندسية فائقة الرقة (Subtle Ledger Grid)
        CustomPaint(
          size: Size.infinite,
          painter: _LedgerGridPainter(),
        ),

        // 5. المحتوى الرئيسي
        child,
      ],
    );
  }
}

class _LedgerGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.02)
      ..strokeWidth = 1.0;

    const double step = 48.0;

    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
