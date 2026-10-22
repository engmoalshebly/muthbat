import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../core/config/supabase_config.dart';

class BusinessLogoAvatar extends StatelessWidget {
  const BusinessLogoAvatar({
    super.key,
    required this.name,
    this.path = '',
    this.preview,
    this.size = 56,
  });

  final String name;
  final String path;
  final Uint8List? preview;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Center(
      child: Text(
        name.trim().isEmpty ? 'م' : name.trim().characters.first,
        style: TextStyle(
          color: AppColors.primary,
          fontSize: size * .4,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    return Semantics(
      label: 'شعار المتجر',
      image: true,
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: preview != null
              ? Image.memory(
                  preview!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => fallback,
                )
              : path.isNotEmpty
              ? Image.network(
                  '${SupabaseConfig.effectiveUrl}/storage/v1/object/public/business-assets/${path.split('/').map(Uri.encodeComponent).join('/')}',
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => fallback,
                  loadingBuilder: (_, child, progress) =>
                      progress == null ? child : fallback,
                )
              : fallback,
        ),
      ),
    );
  }
}
