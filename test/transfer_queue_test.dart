import 'package:flutter_test/flutter_test.dart';
import 'package:quick_transfer_desktop/transfer_queue.dart';

void main() {
  test('drain returns queued messages once for a device ip', () {
    final queue = TransferQueue();
    final message = {'type': 'clipboard', 'content': 'hello'};

    queue.enqueue('192.168.1.20', message);

    expect(queue.drain('192.168.1.20'), [message]);
    expect(queue.drain('192.168.1.20'), isEmpty);
  });

  test('queues are isolated per device ip', () {
    final queue = TransferQueue();
    final first = {'type': 'text', 'content': 'first'};
    final second = {'type': 'text', 'content': 'second'};

    queue.enqueue('192.168.1.20', first);
    queue.enqueue('192.168.1.21', second);

    expect(queue.drain('192.168.1.21'), [second]);
    expect(queue.drain('192.168.1.20'), [first]);
  });
}
