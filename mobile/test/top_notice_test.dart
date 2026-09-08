import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/shared/widgets/top_notice.dart';

void main() {
  testWidgets('notice appears above content and a second message replaces it', (tester) async {
    late BuildContext screen;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      screen = context;
      return const Scaffold(body: Center(child: Text('الدفتر')));
    })));
    TopNotice.of(screen).showSnackBar(const SnackBar(content: Text('تم الحفظ')));
    await tester.pump();
    expect(tester.getTopLeft(find.text('تم الحفظ')).dy, lessThan(120));
    TopNotice.of(screen).showSnackBar(const SnackBar(content: Text('عملية ثانية')));
    await tester.pump();
    expect(find.text('تم الحفظ'), findsNothing);
    expect(find.text('عملية ثانية'), findsOneWidget);
    await tester.tap(find.byTooltip('إغلاق'));
    await tester.pump();
    expect(find.text('عملية ثانية'), findsNothing);
  });
}
