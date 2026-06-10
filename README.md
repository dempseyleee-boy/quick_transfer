# Quick Transfer

Quick Transfer is a Flutter desktop + Android LAN transfer tool. It supports
messages, clipboard text, and file transfer between a Linux desktop and an
Android phone on the same local network.

## Features

- Linux desktop app and Android mobile app.
- Device discovery and manual IP connection.
- Desktop-to-phone direct push through `POST /api/send`.
- Fallback queue on the desktop when the phone is temporarily unreachable.
- Phone polling through `/api/messages` to drain queued desktop payloads.
- Clipboard, text message, and file transfer.
- Android-side local HTTP receiver on port `8765`.

## Current Scope

Screen casting is not implemented yet. A previous placeholder button was
removed because it only attempted a one-off desktop screenshot and the Android
app did not handle that payload type.

## Network Model

Both devices must be on the same LAN/Wi-Fi network for normal transfer.

The Android app listens on:

```text
http://<phone-ip>:8765
```

Useful smoke checks:

```bash
curl http://<phone-ip>:8765/api/status
curl -X POST http://<phone-ip>:8765/api/send \
  -H 'Content-Type: application/json' \
  -d '{"type":"clipboard","content":"hello"}'
```

For USB-only debugging, forward the Android receiver:

```bash
adb forward tcp:18765 tcp:8765
curl http://127.0.0.1:18765/api/status
```

## Desktop Development

Use Flutter 3.24.5 or compatible.

On Linux, Flutter expects `clang++` and `ninja`. If the host only has `g++`, a
temporary local shim can be used:

```bash
mkdir -p toolbin
ln -sf /usr/bin/g++ toolbin/clang++
PATH="$PWD/toolbin:$PATH" flutter run -d linux
```

Run checks:

```bash
flutter test
flutter analyze
```

## Android Development

The mobile app is under `mobile/`.

Build debug APK:

```bash
cd mobile
flutter pub get
flutter build apk --debug
```

Install:

```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

If an existing app was installed with a different signature, uninstall first:

```bash
adb uninstall com.quicktransfer.quick_transfer_mobile
```

## Verified

- Desktop tests pass.
- Desktop analyze reports no issues.
- Android debug APK builds.
- Android APK installs and starts on a vivo V2405A.
- USB-forwarded and LAN `/api/status` and `/api/send` smoke tests pass.

## Notes

- The Android debug build uses Android Gradle Plugin `8.5.1`, Gradle `8.7`,
  and `compileSdk = 35`.
- `android:usesCleartextTraffic="true"` is enabled for LAN HTTP transfer.
- See `docs/superpowers/plans/2026-06-11-quick-transfer-recovery.md` for the
  recovery and verification plan used during this update.
