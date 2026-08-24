import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../core/constants/asset_paths.dart';

enum LogoVariant {
  primary,
  iconOnly,
  white,
  splash,
}

/// عنصر عرض شعار «مُثبَت» المعتمد والرموز المرئية
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
    switch (variant) {
      case LogoVariant.primary:
        return Image.asset(
          AssetPaths.logoPng,
          width: width ?? 200,
          height: height,
          fit: fit,
          errorBuilder: (context, error, stackTrace) => SvgPicture.asset(
            AssetPaths.logoPrimary,
            width: width ?? 200,
            height: height,
            fit: fit,
          ),
        );
      case LogoVariant.iconOnly:
        return Image.asset(
          AssetPaths.iconPng,
          width: width ?? 72,
          height: height ?? 72,
          fit: fit,
          errorBuilder: (context, error, stackTrace) => SvgPicture.asset(
            AssetPaths.logoIcon,
            width: width ?? 72,
            height: height ?? 72,
            fit: fit,
          ),
        );
      case LogoVariant.splash:
        return Image.asset(
          AssetPaths.splashPng,
          width: width ?? 160,
          height: height ?? 160,
          fit: fit,
          errorBuilder: (context, error, stackTrace) => SvgPicture.asset(
            AssetPaths.logoPrimary,
            width: width ?? 160,
            height: height ?? 160,
            fit: fit,
          ),
        );
      case LogoVariant.white:
        return SvgPicture.asset(
          AssetPaths.logoWhite,
          width: width ?? 180,
          height: height,
          fit: fit,
        );
    }
  }
}
