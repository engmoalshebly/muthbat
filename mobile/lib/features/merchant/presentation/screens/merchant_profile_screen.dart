import 'package:flutter/material.dart';

import 'merchant_home_screen.dart';

/// Keeps existing profile links on the single merchant settings surface.
class MerchantProfileScreen extends StatelessWidget {
  const MerchantProfileScreen({super.key});

  @override
  Widget build(BuildContext context) => const MerchantHomeScreen(initialTab: 3);
}
