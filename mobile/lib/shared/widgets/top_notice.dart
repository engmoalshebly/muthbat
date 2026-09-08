import 'dart:async';
import 'package:flutter/material.dart';

/// Replaces transient bottom messages without covering keyboard or FAB actions.
class TopNotice {
  TopNotice._(this.context);
  final BuildContext context;
  static OverlayEntry? _entry;
  static Timer? _timer;
  static TopNotice of(BuildContext context) => TopNotice._(context);

  void hideCurrentSnackBar() {
    _timer?.cancel();
    _entry?.remove();
    _entry = null;
  }

  void showSnackBar(SnackBar notice) {
    hideCurrentSnackBar();
    if (!context.mounted) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final theme = Theme.of(context);
    _entry = OverlayEntry(
      builder: (_) => Positioned(
        top: 0,
        left: 12,
        right: 12,
        child: SafeArea(
          bottom: false,
          child: Material(
            color: notice.backgroundColor ?? theme.colorScheme.inverseSurface,
            elevation: 8,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: DefaultTextStyle(
                style: theme.textTheme.bodyMedium!.copyWith(
                  color: theme.colorScheme.onInverseSurface,
                ),
                child: Row(
                  children: [
                    Expanded(child: notice.content),
                    if (notice.action != null)
                      TextButton(
                        onPressed: () {
                          hideCurrentSnackBar();
                          notice.action!.onPressed();
                        },
                        child: Text(notice.action!.label),
                      ),
                    IconButton(
                      tooltip: 'إغلاق',
                      onPressed: hideCurrentSnackBar,
                      icon: Icon(
                        Icons.close,
                        color: theme.colorScheme.onInverseSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
    _timer = Timer(notice.duration, hideCurrentSnackBar);
  }
}
