# RunFuel Android build and download

GitHub Actions builds the Android ARM64 release APK from the Flutter source in `app/` using [`.github/workflows/android-apk.yml`](../.github/workflows/android-apk.yml).

## Download

1. Open the repository's **Actions** tab.
2. Select **Build RunFuel Android APK**.
3. Select **Run workflow**, or open a run started by a source change.
4. Wait for the workflow to complete successfully.
5. Open the completed run and find **Artifacts**.
6. Download **RunFuel-Android-ARM64** and extract the ZIP.
7. Install `RunFuel-Android-ARM64.apk`.

The app's launcher name is **RunFuel**. GitHub Actions artifacts expire after 14 days.

## Signing and updates

For permanent signing, configure these four GitHub Actions repository secrets:

- `RUNFUEL_KEYSTORE_BASE64`
- `RUNFUEL_STORE_PASSWORD`
- `RUNFUEL_KEY_ALIAS`
- `RUNFUEL_KEY_PASSWORD`

They must belong to the same long-term Android signing key. Never commit the keystore or passwords. The workflow validates the keystore and alias before using them.

If all four secrets are absent, CI builds with Flutter's generated debug signing configuration. This is suitable for a fresh test install, but Android will not install it over an APK signed with a different key. If only some secrets are configured, the workflow fails rather than silently producing a differently signed artifact.

**Important:** To update an existing RunFuel installation, use the same signing key that was used for that installation. Do not uninstall first unless you have backed up local-only app data.

## Local build

Install Flutter stable, Java 17, and the Android SDK:

    cd app
    flutter pub get
    flutter test
    flutter analyze
    flutter build apk --release --target-platform android-arm64

The local output is normally `build/app/outputs/flutter-apk/app-release.apk`.
