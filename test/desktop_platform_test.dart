import 'package:flutter_test/flutter_test.dart';
import 'package:quick_transfer_desktop/desktop_platform.dart';

void main() {
  test('recognizes common private IPv4 ranges', () {
    expect(isPrivateIPv4Address('10.1.2.3'), isTrue);
    expect(isPrivateIPv4Address('172.16.0.1'), isTrue);
    expect(isPrivateIPv4Address('172.31.255.254'), isTrue);
    expect(isPrivateIPv4Address('192.168.1.10'), isTrue);
  });

  test('rejects public or invalid IPv4 addresses', () {
    expect(isPrivateIPv4Address('8.8.8.8'), isFalse);
    expect(isPrivateIPv4Address('172.32.0.1'), isFalse);
    expect(isPrivateIPv4Address('192.167.1.10'), isFalse);
    expect(isPrivateIPv4Address('not an ip'), isFalse);
  });
}
