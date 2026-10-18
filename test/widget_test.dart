import 'package:flutter_test/flutter_test.dart';
import 'package:mirroring/main.dart';

void main() {
  testWidgets('SelfieMirrorApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SelfieMirrorApp());
    expect(find.byType(SelfieMirrorApp), findsOneWidget);
  });
}
