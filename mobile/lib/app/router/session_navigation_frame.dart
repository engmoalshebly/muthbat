import 'package:flutter/material.dart';

/// The Navigator must keep the same element slot as session banners change,
/// including while a Hero flight or route animation is in progress.
class SessionNavigationFrame extends StatelessWidget {
  const SessionNavigationFrame({
    super.key,
    required this.showBanner,
    required this.banner,
    required this.child,
  });
  final bool showBanner;
  final Widget banner;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Visibility(visible: showBanner, child: banner),
      Expanded(child: child),
    ],
  );
}
