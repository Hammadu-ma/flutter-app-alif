# Alif Med — Flutter WebView App

A lightweight Flutter wrapper for **alifmeta.vercel.app**, built to feel like a real native app rather than "a website in a box":

- Modern WebView with pull-to-refresh
- Real ALIF logo as the app icon (adaptive icon on Android) and splash mark
- Native Android splash shows the logo instantly — before Flutter even starts
- Smart offline handling: only shows the "no internet" screen when there's genuinely nothing cached to show; otherwise it tries to serve from cache and reconnects automatically the moment you're back online
- Smooth navigation: a full branded loading screen only appears on the very first cold start — every navigation after that (in-app links, pull-to-refresh, SPA route changes) gets a slim animated top progress bar instead, so the app never looks "stuck"
- Offline / connection-error screens with a Retry button
- Android back button navigates within the site (not straight out of the app)
- Fast startup, minimal dependencies

## v1.1.1 fix — system theme (dark mode) stopped working
Your site already supports `prefers-color-scheme` in CSS, but Android WebView silently ignores that media query for any app targeting Android 13 (API 33) or higher — unless "algorithmic darkening" is turned on explicitly, per WebView instance, from native code. There's no Dart-level API for this in `webview_flutter`, so it's now set natively in `android/.../MainActivity.kt`: it watches the view tree for the WebView and enables `WebSettingsCompat.setAlgorithmicDarkeningAllowed(...)` on it as soon as it appears. This needed a new `androidx.webkit` dependency, added to both `android/app/build.gradle` and the Codemagic build script so it applies whether you build locally or on CI. Your site's system-theme support should follow the device's light/dark setting again.

## What changed in this update (v1.1.0)
- **Real logo everywhere** — the provided ALIF mark now drives the splash screen, the Flutter loading overlay, and the Android launcher icon (both the classic square icon and a proper adaptive icon with a transparent, safe-zone-padded foreground layer). All of the generated PNG/XML resources are already baked into `android/app/src/main/res/`, so this works even without re-running the icon/splash generator tools.
- **Faster, non-blocking splash** — the OS-level native splash (`android/.../values-v31/styles.xml`, Android 12+ Splash Screen API) now shows the logo immediately, and the in-app loading screen crossfades out instead of cutting away abruptly. A first load that's taking a while shows a small "still on it" hint instead of looking frozen.
- **Offline-aware loading** (`lib/main.dart`):
  - On a cold start with no network *and* nothing ever loaded before, it skips straight to the offline screen instead of spinning uselessly.
  - On a cold start with no network but the app *has* loaded successfully before, it still attempts to load (letting the WebView's own HTTP cache serve whatever it has) and only falls back to the offline screen if nothing renders.
  - The moment connectivity returns, it reloads automatically — no manual retry needed.
  - True offline support for dynamic content ultimately depends on the **website** having a service worker / cache headers to actually cache its pages; the wrapper app can only serve what the browser engine has cached. If you want the site to keep working with zero connectivity (not just resume quickly), that piece has to be added on the Alif Med web app itself (e.g. a PWA service worker).
- **Smooth page-to-page navigation** — a slim animated progress bar now runs along the top of the screen for every navigation after the first (in-app links, pull-to-refresh, and client-side/SPA route changes), instead of a full-screen reload flash.

This is a **complete Flutter project source** — not a compiled app — because building an actual `.apk`/`.ipa` requires the Flutter SDK, Android SDK (and a Mac + Xcode for iOS), which aren't available in this environment. Below is exactly how to turn it into an installable app in a few minutes.

## What's included
```
alif_meta_app/
├── lib/main.dart          ← all app logic (webview, splash, error/offline states)
├── pubspec.yaml            ← dependencies + icon/splash config
├── assets/
│   ├── app_icon.png             ← your real logo, opaque (Flutter asset + fallback launcher icon)
│   ├── app_icon_foreground.png  ← transparent, safe-zone-padded — Android adaptive icon foreground
│   └── splash_logo.png          ← transparent, safe-zone-padded — splash mark
└── android/                ← full, ready-to-build Android project (icons + splash already generated)
```
iOS platform files aren't included (a valid Xcode project can't be hand-authored safely) — see step 4 to add iOS support in one command.

## 1. Install Flutter
If you don't already have it: https://docs.flutter.dev/get-started/install
Verify with:
```
flutter doctor
```

## 2. Set your local SDK path
Open `android/local.properties` and set:
```
sdk.dir=/path/to/your/Android/sdk
flutter.sdk=/path/to/your/flutter
```
(Android Studio fills this in automatically if you open the project there instead.)

## 3. Get packages
```
cd alif_meta_app
flutter pub get
```

## 4. (Optional) Add iOS support
```
flutter create --platforms=ios .
```
This only adds the missing `ios/` folder — it won't touch your `lib/`, `pubspec.yaml`, or `android/`.

## 5. Icon and splash image
Your real ALIF logo is already wired in and the Android resources (launcher icon, adaptive icon, splash) are pre-generated in `android/app/src/main/res/`, so there's nothing to do here. If you ever swap the logo again later, replace the three files in `assets/` and re-run:
```
flutter pub run flutter_launcher_icons
flutter pub run flutter_native_splash:create
```

## 6. Run it
```
flutter run
```

## 7. Build a release APK
```
flutter build apk --release
```
Output: `build/app/outputs/flutter-apk/app-release.apk`

For the Play Store, build an app bundle instead, and add a real signing config in `android/app/build.gradle` first (currently signed with the debug key as a placeholder):
```
flutter build appbundle --release
```

## Changing the URL
Everything points at one constant near the top of `lib/main.dart`:
```dart
const String kAppUrl = 'https://alifmeta.vercel.app';
```

## Fixed: Codemagic trying to build iOS too (and failing)
Codemagic's default workflow builds both Android and iOS. Since this project has no `ios/` folder, that step fails with `Did not find xcodeproj`, even though the Android build itself succeeds. A `codemagic.yaml` is now included at the project root that defines an **Android-only** workflow. On Codemagic, go to your app → **Workflow editor** → switch from the default workflow to **"Alif Med - Android"** (it's auto-detected from this file) → Start new build.

## Fixed: Gradle version build error
An earlier version of this project didn't pin a Gradle wrapper version, which caused newer Flutter releases to fail with:
```
Your project's Gradle version (8.4.0) is lower than Flutter's minimum supported version of 8.7.0
```
This is now fixed — `android/gradle/wrapper/gradle-wrapper.properties` pins Gradle 8.9, and `android/build.gradle` / `android/settings.gradle` use AGP 8.7.3 with Kotlin 2.1.0, a known-compatible combination. If you re-run the build (locally or on Codemagic), it should now complete.

## Notes
- App ID is `com.alifmed.app` — change it in `android/app/build.gradle` (`applicationId`) and the Kotlin package path before publishing if you want something else.
- `usesCleartextTraffic` is `false`, since your site is served over HTTPS — no change needed unless you add non-HTTPS content.
