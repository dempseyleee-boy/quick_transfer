import 'dart:io';

import 'package:path/path.dart' as p;

const _fallbackFileName = 'received_file';

String sanitizeReceivedFileName(Object? value) {
  final raw = value?.toString().trim() ?? '';
  final basename = p.posix.basename(p.windows.basename(raw));
  final withoutControlChars = basename.replaceAll(RegExp(r'[\x00-\x1F]'), '');
  final withoutInvalidWindowsChars =
      withoutControlChars.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  final trimmed =
      withoutInvalidWindowsChars.trim().replaceAll(RegExp(r'[. ]+$'), '');
  final reserved = RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
      caseSensitive: false);

  if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') {
    return _fallbackFileName;
  }

  if (reserved.hasMatch(trimmed)) {
    return '_$trimmed';
  }

  return trimmed;
}

Future<String> nextAvailableFilePath(String directory, Object? rawName) async {
  final fileName = sanitizeReceivedFileName(rawName);
  final extension = p.extension(fileName);
  final basename = p.basenameWithoutExtension(fileName);

  var candidate = p.join(directory, fileName);
  var suffix = 1;

  while (await File(candidate).exists() || await Directory(candidate).exists()) {
    candidate = p.join(directory, '$basename ($suffix)$extension');
    suffix += 1;
  }

  return candidate;
}
