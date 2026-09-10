import 'package:flutter/material.dart';

/// Free account-book colors, independent of merchant/customer workspaces.
class LocalPalette {
  LocalPalette._();
  static const canvas = Color(0xFFF0F7F6);
  static const ink = Color(0xFF123B46);
  static const teal = Color(0xFF00796B);
  static const mint = Color(0xFFD7F3EA);
  static const gold = Color(0xFFFFD166);
  static const goldSurface = Color(0xFFFFF0CA);
  static const debt = Color(0xFFB83245);
  static const payment = Color(0xFF087443);
  static const secondaryText = Color(0xFF46615F);
  static const hero = LinearGradient(
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
    colors: [Color(0xFF00796B), Color(0xFF075968), Color(0xFF123B46)],
  );
}
