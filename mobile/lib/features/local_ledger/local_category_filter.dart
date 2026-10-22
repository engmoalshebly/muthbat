import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_icons.dart';

String ledgerCategory(Map entry) {
  final value = entry['category']?.toString().trim() ?? '';
  return value.isEmpty ? 'غير مصنف' : value;
}

class LocalCategoryFilter extends StatelessWidget {
  const LocalCategoryFilter({
    super.key,
    required this.entries,
    required this.value,
    required this.onChanged,
  });
  final Iterable entries;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final categories =
        entries.map((e) => ledgerCategory(e as Map)).toSet().toList()..sort();
    if (value != null && !categories.contains(value)) categories.add(value!);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: 1,
      child: PopupMenuButton<String>(
        tooltip: 'تصفية حسب التصنيف',
        initialValue: value ?? '',
        itemBuilder: (_) => [
          CheckedPopupMenuItem(
            value: '',
            checked: value == null,
            child: const Text('كل التصنيفات'),
          ),
          for (final category in categories)
            CheckedPopupMenuItem(
              value: category,
              checked: value == category,
              child: Text(category),
            ),
        ],
        onSelected: (v) => onChanged(v == '' ? null : v),
        child: CompactFilterLabel(
          icon: AppIcons.filter,
          label: value ?? 'كل التصنيفات',
          active: value != null,
        ),
      ),
    );
  }
}

class CompactFilterLabel extends StatelessWidget {
  const CompactFilterLabel({
    super.key,
    required this.icon,
    required this.label,
    this.active = false,
  });
  final IconData icon;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.primary : AppColors.textSecondary;
    return Container(
      constraints: const BoxConstraints(minHeight: 40, maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: active ? AppColors.primaryContainer : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: active
              ? AppColors.primary.withValues(alpha: .2)
              : AppColors.borderLight,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Icon(AppIcons.chevronDown, size: 13, color: color),
        ],
      ),
    );
  }
}
