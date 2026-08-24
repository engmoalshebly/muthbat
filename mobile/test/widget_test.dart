import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:muthbat/app/app.dart';

void main() {
  testWidgets('MuthbatApp boots and renders SplashScreen', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MuthbatApp(),
      ),
    );

    // التحقق من ظهور نصوص وشعارات الشاشة الافتتاحية
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('مُثبَت'), findsWidgets);

    // إنهاء مؤقتات الشاشة الافتتاحية والانتقال لشاشة الدخول
    await tester.pumpAndSettle(const Duration(milliseconds: 3000));
  });
}
