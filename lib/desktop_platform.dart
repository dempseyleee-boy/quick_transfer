import 'dart:io';

import 'package:path/path.dart' as p;

class DesktopPlatform {
  static String get label {
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isMacOS) return 'macOS';
    return Platform.operatingSystem;
  }

  static String get appTitle => '快传 - $label 端';

  static String get deviceName {
    if (Platform.isWindows) return 'Windows PC';
    if (Platform.isLinux) return 'Linux PC';
    if (Platform.isMacOS) return 'Mac';
    return '$label PC';
  }
}

bool isPrivateIPv4Address(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return false;

  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
    octets.add(value);
  }

  return octets[0] == 10 ||
      (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (octets[0] == 192 && octets[1] == 168);
}

Future<String?> findPreferredLocalIPv4() async {
  final candidates = <InternetAddress>[];
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLinkLocal: false,
  );

  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (!address.isLoopback) {
        candidates.add(address);
      }
    }
  }

  for (final address in candidates) {
    if (isPrivateIPv4Address(address.address)) {
      return address.address;
    }
  }

  return candidates.isEmpty ? null : candidates.first.address;
}

Future<void> revealPathInFileManager(String path) async {
  if (Platform.isWindows) {
    await Process.run('explorer.exe', ['/select,${path.replaceAll('/', r'\')}']);
    return;
  }

  if (Platform.isMacOS) {
    await Process.run('open', ['-R', path]);
    return;
  }

  final type = await FileSystemEntity.type(path);
  final target = type == FileSystemEntityType.directory ? path : p.dirname(path);
  await Process.run('xdg-open', [target]);
}
