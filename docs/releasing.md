# Release Guide

Quick Transfer release packages are produced by GitHub Actions from version
tags. Do not commit APK, AAB, Debian, zip, keystore, or signing-property files
to the repository.

Windows releases are distributed as zip bundles attached to GitHub Releases.
Do not publish only `quick_transfer.exe`; the Flutter runtime files next to it
are required. GitHub Packages is not used for these desktop binaries because
release assets are easier for users to download and match the existing Linux
and Android release flow.

## Android Signing Secrets

Create a private Android upload keystore and keep an offline backup. Configure
these GitHub Actions repository secrets:

- `ANDROID_KEYSTORE_BASE64`: Base64-encoded contents of the keystore.
- `ANDROID_KEYSTORE_PASSWORD`: Keystore password.
- `ANDROID_KEY_PASSWORD`: Key password.
- `ANDROID_KEY_ALIAS`: Key alias.

Example encoding command:

```bash
base64 -w 0 upload-keystore.jks
```

Never commit the encoded value or the decoded keystore.

For a local signed build, create `mobile/android/key.properties`:

```properties
storePassword=<keystore-password>
keyPassword=<key-password>
keyAlias=<key-alias>
storeFile=upload-keystore.jks
```

Place the keystore at `mobile/android/upload-keystore.jks`, then run:

```bash
cd mobile
flutter build apk --release
flutter build appbundle --release
```

Release builds fail when `key.properties` is absent. They never fall back to
the Android Debug certificate.

## Windows Package

GitHub Actions builds the Windows x64 bundle on `windows-2022` and uploads:

- `quick-transfer_<version>_windows_x64.zip`
- `quick-transfer_<version>_windows_x64.zip.sha256`

For a local package:

```powershell
flutter pub get
flutter build windows --release
Compress-Archive `
  -Path build/windows/x64/runner/Release/* `
  -DestinationPath quick-transfer_2.0.0_windows_x64.zip
$hash = Get-FileHash quick-transfer_2.0.0_windows_x64.zip -Algorithm SHA256
"$($hash.Hash.ToLower())  quick-transfer_2.0.0_windows_x64.zip" |
  Out-File quick-transfer_2.0.0_windows_x64.zip.sha256 -Encoding ascii
```

Upload the zip and checksum as GitHub Release assets. Do not commit them to the
source tree.

## Publish A Release

1. Set the same public version in `pubspec.yaml` and `mobile/pubspec.yaml`.
2. Increment the Android build number after `+` in `mobile/pubspec.yaml`.
3. Run:

   ```bash
   bash tool/verify_release_config.sh
   flutter test
   flutter analyze
   (cd mobile && flutter test && flutter analyze)
   ```

4. Commit and push the version change.
5. Create and push a matching tag:

   ```bash
   git tag -a v2.0.0 -m "Quick Transfer 2.0.0"
   git push origin v2.0.0
   ```

The tag workflow publishes:

- Signed Android APK.
- Signed Android AAB.
- Linux amd64 Debian package.
- Windows x64 zip bundle.
- SHA-256 checksum files.

The release workflow fails rather than publishing an unsigned or Debug-signed
Android package when signing secrets are missing.
