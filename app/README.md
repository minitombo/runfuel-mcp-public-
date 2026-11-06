# RunFuel Android app

This folder contains the public Flutter source for the RunFuel Android app. RunFuel brings training plans, Garmin activity and recovery, MyFitnessPal nutrition, food diary review and coaching into one Android client.

The app can be used independently of the optional RunFuel MCP backend. No personal Garmin/MyFitnessPal credentials, health records, Gemini API key or Android signing key are included in this repository.

## Build and install

1. Open this repository's **Actions** tab.
2. Select **Build RunFuel Android APK** and run the workflow, or use a successful build triggered by a source change.
3. Download the **RunFuel-Android-ARM64** artifact and extract the APK.
4. Install it on a compatible ARM64 Android phone.

For updates to an existing installation, the APK must be signed with the same permanent key as the installed app. Configure your own four signing secrets as described in [BUILD.md](BUILD.md). Without those secrets, the public workflow creates a debug-signed APK suitable for fresh installs, not updates over a differently signed RunFuel build.

## First-time setup

1. Open RunFuel and go to **Settings**.
2. Leave the backend URL blank if you only want to use features that do not require Garmin/MyFitnessPal sync.
3. If connecting your own RunFuel backend, enter its HTTPS base URL only, for example `https://your-project.vercel.app`. Do not add `/mcp`, `/settings`, or a trailing slash.
4. Connect Garmin from **Settings → Connections**, then sync when you want to refresh saved activity and wellness history.
5. Connect MyFitnessPal from **Settings → Connections → Connect MyFitnessPal** and complete the sign-in flow inside the app.
6. Use the Home, Training and Food tabs to review activity, training plans, nutrition and recovery.

The Android app's MyFitnessPal sign-in is separate from the MCP/Claude account-connection flow. You can use the Android app without configuring Claude or the MCP endpoint.

## AI coaching

In-app Gemini coaching uses your own Google AI Studio API key. No shared maintainer key is included. Configure it from **AI Coach → Coaching tools → Configure Gemini API key**. Review the data-sharing preview before approving each request. See [AI_OPTIONS.md](AI_OPTIONS.md) for the data sent, Google's terms and alternatives.

RunFuel also retains the **Open ChatGPT**, **Paste Reply**, and **Export coaching history** workflows. RunFuel opens Android's share sheet; it does not automatically send your data to ChatGPT.

## Repository layout

- `lib/` — Flutter application source.
- `test/` — Flutter unit and widget tests.
- [BUILD.md](BUILD.md) — GitHub Actions build, artifacts and Android signing.
- [AI_OPTIONS.md](AI_OPTIONS.md) — AI setup, privacy and chat options.

The Android Gradle platform scaffold is generated during CI with Flutter. It is not committed as a pre-generated Android project.

## Development

Install Flutter stable, Java 17 and the Android SDK, then run:

    cd app
    flutter pub get
    flutter test
    flutter analyze

Do not commit local build output, signing keys, keystores, passwords, cookies, provider API keys, personal health data or environment files.
