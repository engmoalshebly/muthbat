import 'package:flutter/material.dart';

/// A shared, card-free role switch for sign-in and registration.
class AuthRoleTabs extends StatelessWidget {
  const AuthRoleTabs({
    super.key,
    required this.customerSelected,
    required this.onChanged,
  });

  final bool customerSelected;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [_tab(context, customer: true), _tab(context, customer: false)],
  );

  Widget _tab(BuildContext context, {required bool customer}) {
    final selected = customerSelected == customer;
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          onTap: onChanged == null ? null : () => onChanged!(customer),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.only(top: 9),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.outlineVariant)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      customer
                          ? Icons.person_outline_rounded
                          : Icons.storefront_outlined,
                      size: 19,
                      color: selected
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      customer ? 'حساب زبون' : 'حساب تاجر',
                      style: TextStyle(
                        fontSize: 14,
                        color: selected
                            ? colors.primary
                            : colors.onSurfaceVariant,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 11),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  width: selected ? 46 : 0,
                  height: 3,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
