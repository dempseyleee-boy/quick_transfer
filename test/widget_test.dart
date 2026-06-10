import 'package:flutter_test/flutter_test.dart';
import 'package:quick_transfer_desktop/main.dart';

void main() {
  testWidgets('desktop home lays out without render exceptions',
      (WidgetTester tester) async {
    await tester.pumpWidget(const QuickTransferDesktop());
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
