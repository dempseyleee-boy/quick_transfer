# Quick Transfer Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stabilize the desktop-to-mobile push plus polling fallback feature and produce a debug Android APK that can be installed and tested over USB.

**Architecture:** The desktop app attempts direct HTTP delivery to the mobile app at `http://<phone-ip>:8765/api/send`. If direct delivery fails, the desktop app stores the payload in an in-memory per-device queue, and the mobile app drains that queue through the existing `/api/messages` polling endpoint. The mobile app hosts a small local HTTP server for direct push and keeps the existing polling path as fallback.

**Tech Stack:** Flutter 3.24.5, Dart 3.5.4, Android Gradle Plugin, Gradle 8.3, Android SDK 35, adb.

---

## Evidence

- `flutter build apk --debug` fails before APK packaging.
- The stable failure is `flutter_plugin_android_lifecycle requires Android SDK version 35 or higher`.
- The same build then fails during `:flutter_plugin_android_lifecycle:compileDebugJavaWithJavac` while transforming `/home/dempsey/Android/Sdk/platforms/android-35/core-for-system-modules.jar` through `jlink`.
- Current project config is `compileSdk = 34` and Android Gradle Plugin `8.1.0`.
- Current Java is Android Studio JBR Java 21 at `/home/dempsey/Downloads/android-studio-panda1-linux/android-studio/jbr`.

## File Map

- Modify: `mobile/android/app/build.gradle`
  - Set `compileSdk = 35` to satisfy plugin requirements.
- Modify: `mobile/android/settings.gradle`
  - Upgrade Android Gradle Plugin from `8.1.0` to a Java 21 compatible version already seen in dependency resolution, `8.5.1`.
- Modify: `mobile/android/gradle.properties`
  - Suppress only the expected compileSdk warning if needed.
- Keep: `mobile/lib/main.dart`
  - Mobile direct-push server implementation.
- Keep: `lib/main.dart`
  - Desktop direct-push plus queue fallback implementation.
- Keep: `lib/transfer_queue.dart`
  - Per-device pending message queue.
- Test: `test/transfer_queue_test.dart`
  - Queue behavior unit tests.

## Task 1: Android Build Toolchain Fix

**Files:**
- Modify: `mobile/android/app/build.gradle`
- Modify: `mobile/android/settings.gradle`
- Modify: `mobile/android/gradle.properties`

- [ ] **Step 1: Reproduce the failure**

Run:
```bash
PATH=/home/dempsey/flutter_3.24.5/bin:/home/dempsey/Android/Sdk/platform-tools:$PATH \
JAVA_HOME=/home/dempsey/Downloads/android-studio-panda1-linux/android-studio/jbr \
ANDROID_HOME=/home/dempsey/Android/Sdk \
/home/dempsey/flutter_3.24.5/bin/flutter build apk --debug
```

Expected: FAIL mentioning `requires Android SDK version 35` and `JdkImageTransform`.

- [ ] **Step 2: Apply minimal config fix**

Change:
```gradle
compileSdk = 35
```

Change:
```gradle
id "com.android.application" version "8.5.1" apply false
```

If the warning remains, add:
```properties
android.suppressUnsupportedCompileSdk=35
```

- [ ] **Step 3: Verify build advances or succeeds**

Run the same `flutter build apk --debug` command.

Expected: PASS and produce `mobile/build/app/outputs/flutter-apk/app-debug.apk`, or fail at a new, later error that is not the same `JdkImageTransform` root cause.

## Task 2: Queue Unit Tests

**Files:**
- Test: `test/transfer_queue_test.dart`
- Source: `lib/transfer_queue.dart`

- [ ] **Step 1: Run queue tests**

Run:
```bash
PATH=/home/dempsey/flutter_3.24.5/bin:$PATH /home/dempsey/flutter_3.24.5/bin/flutter test test/transfer_queue_test.dart
```

Expected: PASS.

- [ ] **Step 2: If failing, fix only `lib/transfer_queue.dart`**

Expected queue behavior:
- messages are drained once;
- messages for one device IP do not leak to another IP.

## Task 3: Static Analysis

**Files:**
- Source: `lib/main.dart`
- Source: `mobile/lib/main.dart`
- Source: `mobile/pubspec.yaml`

- [ ] **Step 1: Analyze desktop app**

Run:
```bash
PATH=/home/dempsey/flutter_3.24.5/bin:$PATH /home/dempsey/flutter_3.24.5/bin/flutter analyze
```

Expected: No compile errors. Existing lint-level info messages are acceptable only if unrelated to the feature.

- [ ] **Step 2: Analyze mobile app**

Run from `mobile/`:
```bash
PATH=/home/dempsey/flutter_3.24.5/bin:$PATH /home/dempsey/flutter_3.24.5/bin/flutter analyze
```

Expected: No compile errors. Existing lint-level info messages are acceptable only if unrelated to the feature.

## Task 4: Install and USB Smoke Test

**Files:**
- APK: `mobile/build/app/outputs/flutter-apk/app-debug.apk`

- [ ] **Step 1: Install APK**

Run:
```bash
/home/dempsey/Android/Sdk/platform-tools/adb install -r mobile/build/app/outputs/flutter-apk/app-debug.apk
```

Expected: `Success`.

- [ ] **Step 2: Start mobile app**

Run:
```bash
/home/dempsey/Android/Sdk/platform-tools/adb shell am start -n com.quicktransfer.quick_transfer_mobile/.MainActivity
```

Expected: Activity starts.

- [ ] **Step 3: Forward mobile HTTP server over USB**

Run:
```bash
/home/dempsey/Android/Sdk/platform-tools/adb forward tcp:18765 tcp:8765
curl -s http://127.0.0.1:18765/api/status
```

Expected: JSON with `"type":"mobile"`.

- [ ] **Step 4: Send clipboard payload over USB**

Run:
```bash
curl -s -X POST http://127.0.0.1:18765/api/send \
  -H 'Content-Type: application/json' \
  -d '{"type":"clipboard","content":"quick_transfer usb smoke test"}'
```

Expected: JSON with `"status":"ok"` and no crash in logcat.

## Task 5: LAN Limitation Note

- [ ] **Step 1: Confirm network condition**

Run:
```bash
/home/dempsey/Android/Sdk/platform-tools/adb shell ip addr
```

Expected: For real PC-to-phone LAN transfer, phone must have a Wi-Fi/LAN IP reachable from desktop. USB forwarding only proves the mobile HTTP server and handler work.
