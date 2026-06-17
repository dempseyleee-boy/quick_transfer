# Quick Transfer

Quick Transfer is a local network transfer app for Linux, Windows, and Android. This
first release provides a simple way to exchange messages, clipboard text, and
files between a desktop computer and a phone on the same network.

## Features

- Linux/Windows desktop and Android applications
- Automatic device discovery on the local network
- Manual connection by IP address
- Text message and clipboard transfer
- File transfer between connected devices
- Desktop delivery queue when the phone is temporarily unavailable

## Requirements

- Linux or Windows desktop
- Android phone
- Both devices connected to the same LAN or Wi-Fi network

## Getting Started

Download release packages from the repository's GitHub Releases page. Packages
stored directly in the source tree are not used.

1. Install and start Quick Transfer on the Linux or Windows desktop.
2. Install and start the signed Android app.
3. Keep both devices on the same network.
4. Select the discovered device or enter its IP address manually.
5. Open the appropriate tab to send a message, clipboard text, or file.

## Build From Source

Quick Transfer is built with Flutter 3.24.5.

Build the Linux desktop application:

```bash
flutter pub get
flutter build linux
```

Build the Windows desktop application:

```powershell
flutter pub get
flutter build windows --release
```

Build the Android application:

```bash
cd mobile
flutter pub get
flutter build apk
```

## Development

```bash
flutter test
flutter analyze

cd mobile
flutter test
flutter analyze
```

The Android app runs a local HTTP receiver on port `8765`. You can verify a
connected phone with:

```bash
curl http://<phone-ip>:8765/api/status
```

## Documentation

- [Cross-platform expansion guide](docs/platform-expansion-guide.md)
- [Release guide](docs/releasing.md)
