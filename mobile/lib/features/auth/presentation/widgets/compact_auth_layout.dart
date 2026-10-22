import '../../../../app/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'entry_visual_theme.dart';
import '../../../../shared/widgets/brand_logo.dart';

/// Fits ordinary phone screens; scrolls only when keyboard/text scale requires it.
class CompactAuthLayout extends StatelessWidget {
  const CompactAuthLayout({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    this.showCard = true,
  });
  final String title;
  final String subtitle;
  final List<Widget> children;
  final bool showCard;

  @override
  Widget build(BuildContext context) => EntryVisualTheme(
    child: Scaffold(
      backgroundColor: AppColors.transparent,
      body: EntryBackdrop(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 74,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              const BrandLogo.primary(width: 178),
                              if (Navigator.of(context).canPop())
                                Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: IconButton(
                                    tooltip: MaterialLocalizations.of(
                                      context,
                                    ).backButtonTooltip,
                                    onPressed: () =>
                                        Navigator.maybePop(context),
                                    icon: Icon(
                                      Directionality.of(context) ==
                                              TextDirection.rtl
                                          ? Icons.arrow_forward_rounded
                                          : Icons.arrow_back_rounded,
                                      color: entryInk,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          title,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 20),
                        if (!showCard)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: children,
                          )
                        else
                          Container(
                            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
                            decoration: BoxDecoration(
                              color: AppColors.white,
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: AppColors.entryCardBorder,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: entryBlue.withValues(alpha: .06),
                                  blurRadius: 24,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: children,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

InputDecoration compactAuthDecoration(
  String label, {
  Widget? suffix,
  Widget? prefix,
  String? error,
  Color? fillColor,
}) => InputDecoration(
  labelText: label,
  errorText: error,
  suffixIcon: suffix,
  prefixIcon: prefix,
  isDense: true,
  filled: true,
  fillColor: fillColor ?? AppColors.fieldSurface,
  labelStyle: const TextStyle(color: AppColors.fieldLabel, fontSize: 13),
  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: const BorderSide(color: AppColors.fieldBorder),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: const BorderSide(color: entryBlue, width: 1.8),
  ),
);
