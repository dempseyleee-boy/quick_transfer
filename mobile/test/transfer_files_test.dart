import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quick_transfer_mobile/transfer_files.dart';

void main() {
  test('sanitizes received file names for mobile targets', () {
    expect(sanitizeReceivedFileName('../secret.txt'), 'secret.txt');
    expect(sanitizeReceivedFileName(r'..\secret.txt'), 'secret.txt');
    expect(sanitizeReceivedFileName(r'C:\temp\a:b?.txt'), 'a_b_.txt');
    expect(sanitizeReceivedFileName('NUL.txt'), '_NUL.txt');
    expect(sanitizeReceivedFileName(''), 'received_file');
  });

  test('nextAvailableFilePath avoids overwriting existing files', () async {
    final directory =
        await Directory.systemTemp.createTemp('qt_mobile_files_test_');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    await File(p.join(directory.path, 'photo.jpg')).writeAsString('old');

    final next = await nextAvailableFilePath(directory.path, 'photo.jpg');

    expect(p.basename(next), 'photo (1).jpg');
  });
}
