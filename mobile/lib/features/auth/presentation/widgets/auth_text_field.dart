import 'package:flutter/material.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';

/// حقل إدخال مخصص لشاشات الحسابات والمصادقة
class AuthTextField extends StatelessWidget {
  final String? label;
  final String hintText;
  final TextEditingController? controller;
  final TextInputType keyboardType;
  final Widget? prefixWidget;
  final Widget? suffixIcon;
  final String? errorText;
  final bool obscureText;
  final TextDirection? textDirection;
  final ValueChanged<String>? onChanged;
  final bool autofocus;

  const AuthTextField({
    super.key,
    this.label,
    required this.hintText,
    this.controller,
    this.keyboardType = TextInputType.text,
    this.prefixWidget,
    this.suffixIcon,
    this.errorText,
    this.obscureText = false,
    this.textDirection,
    this.onChanged,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Text(
            label!,
            style: AppTypography.titleSmall(color: AppColors.textPrimary).copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
        ],
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.04),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: TextFormField(
            controller: controller,
            keyboardType: keyboardType,
            obscureText: obscureText,
            autofocus: autofocus,
            textDirection: textDirection,
            onChanged: onChanged,
            style: AppTypography.bodyLarge(color: AppColors.textPrimary).copyWith(
              fontWeight: FontWeight.w600,
            ),
            decoration: InputDecoration(
              hintText: hintText,
              hintStyle: AppTypography.bodyMedium(color: AppColors.textMuted),
              prefixIcon: prefixWidget != null
                  ? Padding(
                      padding: const EdgeInsets.only(left: 12, right: 8),
                      child: prefixWidget,
                    )
                  : null,
              prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
              suffixIcon: suffixIcon,
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: AppColors.borderLight, width: 1.2),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: AppColors.borderLight, width: 1.2),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: AppColors.secondary, width: 1.8),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: AppColors.error, width: 1.5),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: AppColors.error, width: 1.8),
              ),
            ),
          ),
        ),
        if (errorText != null) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              errorText!,
              style: AppTypography.bodySmall(color: AppColors.error).copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
