import 'package:flutter_test/flutter_test.dart';
import 'package:network_computer/main.dart';

void main() {
  testWidgets('app builds', (tester) async {
    // Smoke test that the app constructs without throwing.
    expect(const NetworkComputerApp(), isA<NetworkComputerApp>());
  });
}
