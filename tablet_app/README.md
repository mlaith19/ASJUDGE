# Tablet Monitor – Flutter app

Android tablet app that loads a WebView URL **controlled by the backend**. No WebView URL is hardcoded; it is always fetched from the API.

## Setup

1. Set the backend API base URL in `lib/config/app_config.dart`:
   ```dart
   const String kDefaultApiBaseUrl = 'http://192.168.10.100:5050';
   ```
   Use your server’s LAN IP and port.

2. Install and run:
   ```bash
   flutter pub get
   flutter run
   ```
   Or build release APK:
   ```bash
   flutter build apk --release
   ```
   APK: `build/app/outputs/flutter-apk/app-release.apk`

3. First launch: enter **Judge name** and optional **Tablet label**, then tap **Save and continue**. The app registers with the backend and opens the WebView. The URL shown is the one set in the admin panel (global default or per-tablet override).

## Android

- **Min SDK:** 21  
- **Permissions:** INTERNET, ACCESS_NETWORK_STATE  
- **Cleartext:** `android:usesCleartextTraffic="true"` for LAN HTTP  

If the build fails due to a missing launcher icon, run `flutter create .` then rebuild.

If the build fails with **Gradle/Java version** errors (e.g. "Unsupported class file major version"), ensure your Java version matches Gradle: run `flutter doctor -v` and, if needed, set Java 17 for Flutter or update `android/gradle/wrapper/gradle-wrapper.properties` to a Gradle version compatible with your Java (see [Gradle–Java compatibility](https://docs.gradle.org/current/userguide/compatibility.html)).

## Flow

1. On start: load local config → if setup not done → Setup screen.
2. After setup: register with backend → fetch config → load `targetWebviewUrl` in WebView; apply kiosk/fullscreen and keep-screen-on from config.
3. Every N seconds (from backend config): send heartbeat (battery, WiFi SSID/BSSID, IP, gateway, signal, foreground/kiosk/screen state, etc.), fetch config, reload WebView if URL changed or `forceReload` is true.
4. Back button: if WebView can go back, go back; else in kiosk mode do not exit (message: tap top-left 5× to exit); otherwise show exit dialog.

## Where the WebView URL comes from

- **Only from the backend:** Admin → Settings (global default) or Admin → Tablet → Custom WebView URL.
- The app never hardcodes the target URL; it only uses `targetWebviewUrl` from `GET /api/tablets/:deviceId/config`.

## Kiosk mode

- Full-screen immersive, no app bar; keep screen on; back key does not exit (5 taps in top-left to show exit dialog when kiosk is enabled).
- Config from backend: `kioskModeEnabled`, `keepScreenOn`, optional `expectedWifiSSID`.
- See project root **KIOSK_LIMITATIONS.md** for standard Android vs device-owner behaviour.
