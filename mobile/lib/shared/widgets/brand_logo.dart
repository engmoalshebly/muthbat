import 'package:flutter/material.dart';

import '../../core/constants/asset_paths.dart';

enum LogoVariant { primary, iconOnly, white, splash }

/// Single rendering point for the approved Muthbat brand assets.
class BrandLogo extends StatelessWidget {
  final LogoVariant variant;
  final double? width;
  final double? height;
  final BoxFit fit;

  const BrandLogo({
    super.key,
    this.variant = LogoVariant.primary,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
  });

  const BrandLogo.icon({
    super.key,
    this.width = 72,
    this.height = 72,
    this.fit = BoxFit.contain,
  }) : variant = LogoVariant.iconOnly;

  const BrandLogo.white({
    super.key,
    this.width = 180,
    this.height,
    this.fit = BoxFit.contain,
  }) : variant = LogoVariant.white;

  const BrandLogo.primary({
    super.key,
    this.width = 200,
    this.height,
    this.fit = BoxFit.contain,
  }) : variant = LogoVariant.primary;

  const BrandLogo.splash({
    super.key,
    this.width = 160,
    this.height = 160,
    this.fit = BoxFit.contain,
  }) : variant = LogoVariant.splash;

  @override
  Widget build(BuildContext context) {
    if (variant == LogoVariant.white) {
      return SizedBox(
        width: width ?? 180,
        height: height ?? 40,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          textDirection: TextDirection.rtl,
          children: [
            Image.asset(AssetPaths.mark, fit: BoxFit.contain),
            const SizedBox(width: 4),
            const Text('مُثبَت', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          ],
        ),
      );
    }
    final path = switch (variant) {
      LogoVariant.primary => AssetPaths.horizontalArabic,
      LogoVariant.iconOnly => AssetPaths.mark,
      LogoVariant.white => AssetPaths.mark,
      LogoVariant.splash => AssetPaths.mark,
    };
    return Image.asset(
      path,
      width: width,
      height: height ?? (variant == LogoVariant.primary ? (width ?? 200) * .34 : null),
      fit: fit,
      semanticLabel: 'شعار مُثبَت',
    );
  }
}
