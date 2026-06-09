# Tablet Monitor – WebView control & admin panel

Internal LAN system: Android tablets run a Flutter app that loads a **backend-controlled WebView URL**. Admin panel (Node.js) manages tablets, battery, and target URLs.

---

## Quick start

### הפעלה (משורש הפרויקט)

**שרת (Backend) בלבד:**
```bash
npm install
npm run install:all   # התקנת תלויות ב־server ו־tablet_app (פעם ראשונה)

# אתחול DB (פעם אחת)
cd server && npm run init-db && npm run migrate && npm run seed-admin && cd ..

# הפעלת השרת
npm start
```

**טאבלט (Flutter) – להריץ בנפרד:**
```bash
cd tablet_app
flutter run -d <device_id>
# או: flutter run   (ובחר מכשיר מהרשימה)
```

### 1. Backend בלבד (Node.js)

```bash
cd server
cp .env.example .env
# Edit .env: set PORT, SESSION_SECRET, BACKEND_BASE_URL (e.g. http://192.168.10.100:5000)
npm install
npm run init-db
npm run migrate
npm run seed-admin
npm start
```

- **Admin panel:** http://localhost:5000/admin/login (או כתובת ה-LAN)
- **משתמש פיתוח:** `admin` / `admin123` — **רק לפיתוח; להחליף בפרודקשן.**
- אם כבר קיים DB, להריץ פעם אחת: `npm run migrate`.

### 2. אפליקציית טאבלט בלבד (Flutter)

```bash
cd tablet_app
flutter pub get
# Optional: if Android launcher icon is missing, run: flutter create .  (then rebuild)
flutter run
# Or build APK: flutter build apk --release
```

- Set **backend API URL** in `lib/config/app_config.dart`: `kDefaultApiBaseUrl = 'http://192.168.10.100:5000'` (use your server’s LAN IP).
- First run: complete **Setup** (Judge name, optional Tablet label). Then the app registers and opens the WebView using the URL from the admin panel.

### 3. Admin usage

1. Log in at `/admin/login`.
2. **Settings:** set **Default WebView URL** (e.g. `http://192.168.10.100`), polling interval, optional **Expected WiFi SSID** (for “wrong network” warning), and **Kiosk mode enabled by default**.
3. **Dashboard:** see all tablets, battery, temperature, WiFi SSID/BSSID, IP, gateway, signal, screen/foreground/kiosk state, online/offline, current and target URL, wrong-network warning. Filter by status, low battery, WiFi SSID, wrong network.
4. **Tablet details:** per-tablet custom WebView URL, judge name, label, force reload, note; full device/network and kiosk state.

---

## Project layout

```
server/                 # Node.js backend + admin UI
  src/
    app.js, server.js
    config/
    db/                 # SQLite init, connection, seed
    middleware/         # auth, session
    routes/              # api/tablets, admin (auth, dashboard, settings)
    services/            # admin, settings, tablet
    views/               # EJS admin pages
  .env.example
  package.json

tablet_app/             # Flutter Android app
  lib/
    config/              # kDefaultApiBaseUrl
    models/              # TabletConfig
    services/            # API, storage, device info
    screens/             # Setup, WebView
    utils/               # URL validation
  android/               # Manifest (cleartext, permissions), build.gradle
  pubspec.yaml
```

---

## Changing LAN IP for production

- **Backend:** set `BACKEND_BASE_URL` in `server/.env` to your server’s URL (e.g. `http://192.168.10.100:5000`).
- **Tablet app:** set `kDefaultApiBaseUrl` in `tablet_app/lib/config/app_config.dart` to the same base URL so tablets can reach the API.
- **WebView target URL:** set in Admin → Settings (global default) or per tablet in Dashboard → Edit tablet. No URL is hardcoded in the Flutter app; it always comes from the backend.

---

## API endpoints (tablet app uses these)

| Method | Path | Description |
|--------|------|-------------|
| POST   | `/api/tablets/register`   | Register device (deviceId, judgeName, tabletLabel) |
| POST   | `/api/tablets/heartbeat`  | Send heartbeat (battery, URL, etc.) |
| GET    | `/api/tablets/:deviceId/config` | Get target URL, judge name, polling interval, forceReload, kioskModeEnabled, keepScreenOn, expectedWifiSSID |

---

## Kiosk mode (tablet app)

The tablet app supports full-screen kiosk: immersive UI, keep screen on, and back-button protection (exit only via 5 taps in top-left corner when kiosk is enabled). See **KIOSK_LIMITATIONS.md** for what is possible on standard Android vs device-owner/dedicated device.

---

## Development admin seed

After `npm run seed-admin`:

- **Username:** `admin`  
- **Password:** `admin123`  

**Use only in development.** Create a proper admin user and remove or change this in production.

---

## Requirements

- Node.js 18+
- Flutter SDK (for tablet app)
- Android device/emulator (minSdk 21), LAN access to backend
