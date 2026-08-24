import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_decorations.dart';
import '../../app/theme/app_typography.dart';

class MuthbatNavItem {
  final IconData icon;
  final String label;

  const MuthbatNavItem({required this.icon, required this.label});
}

/// Consistent, compact navigation for the main application shells.
class MuthbatBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<MuthbatNavItem> items;

  const MuthbatBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.navBackground,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: AppColors.navBackground,
            border: const Border(
              top: BorderSide(color: AppColors.borderSubtle),
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.08),
                blurRadius: 18,
                offset: const Offset(0, -5),
              ),
            ],
          ),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Row(
              children: List.generate(items.length, (index) {
                final item = items[index];
                final selected = index == currentIndex;

                return Expanded(
                  child: Semantics(
                    button: true,
                    selected: selected,
                    label: item.label,
                    child: InkWell(
                      onTap: () => onTap(index),
                      borderRadius: AppDecorations.roundedMedium,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                        height: 50,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: selected
                              ? AppColors.primaryContainer
                              : Colors.transparent,
                          borderRadius: AppDecorations.roundedMedium,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              item.icon,
                              size: 21,
                              color: selected
                                  ? AppColors.primary
                                  : AppColors.navInactive,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              item.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  AppTypography.bodySmall(
                                    color: selected
                                        ? AppColors.primary
                                        : AppColors.navInactive,
                                  ).copyWith(
                                    fontSize: 10.5,
                                    fontWeight: selected
                                        ? FontWeight.w800
                                        : FontWeight.w500,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}
