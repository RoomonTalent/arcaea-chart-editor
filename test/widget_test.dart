import 'package:arcaea_manager/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('显示初次启动设置', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ArcaeaManagerApp());
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('添加文件夹'), findsOneWidget);
  });
}
