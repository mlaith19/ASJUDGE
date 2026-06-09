# Kiosk mode: limitations on standard Android

This document describes what the app can and cannot do on **standard Android** (non–device-owner) and how behaviour changes with **dedicated device / device owner** setups.

---

## What the app implements (standard Android)

1. **Immersive full-screen**
   - Status bar and navigation bar are hidden (immersive sticky).
   - WebView uses the full screen; no app bar or visible native controls.
   - System UI can temporarily reappear on swipe; it auto-hides again.

2. **Keep screen on**
   - While the app is in the foreground, the screen stays on (wakelock).
   - When the app is backgrounded or closed, the screen can turn off normally.

3. **Back button**
   - If the WebView can go back in history, back key goes back in the page.
   - If there is no history, the app does **not** exit. In kiosk mode, a message explains that 5 taps in the top-left corner are required to open the exit dialog.
   - So normal users cannot leave the app by pressing back.

4. **Home / Recent**
   - On standard Android we **cannot** block the Home or Recent Apps keys.
   - The user can leave the app via Home or Recent. The app then goes to background and reports `foreground_state: background` to the backend.
   - We do **not** force the app back to the foreground automatically (that would require overlay or device-owner capabilities).

5. **Lock task mode (screen pinning)**
   - The app can call Android’s “start lock task” API, but on standard devices this only works when the **user** pins the app (e.g. via Recent → Pin).
   - We do not set the app as a “lock task launcher”; that would require device owner or a dedicated device profile.
   - When the user has pinned the app, Home and Recent are restricted until the user unpins.

6. **Boot auto-start**
   - A broadcast receiver starts the app after `BOOT_COMPLETED`.
   - Many OEMs allow the user to disable “auto-start” or “run at startup” per app, so behaviour may vary by device.

7. **Power button**
   - We **do not** block the power button or prevent the screen from turning off when the user presses power.
   - That is not possible without system/device-owner privileges.

---

## What is possible with dedicated device / device owner

- **Device owner / managed profile:** the app can be set as a lock task launcher and run in true kiosk mode: back, Home, and Recent can be restricted while the app is pinned.
- **Dedicated device (e.g. Android 9+ “dedicated device” mode):** full kiosk with single-app experience and stronger restrictions.
- **Custom ROM / MDM:** some MDMs can enforce kiosk and prevent uninstall or leaving the app.

The current code is structured so that:
- On standard Android you get immersive full-screen, keep screen on, and protected back (no exit without 5-tap).
- The same app can be deployed as a **lock task** app or on a **dedicated device** to get stricter kiosk behaviour without changing the Flutter logic; only the Android/system configuration changes.

---

## Summary

| Feature                     | Standard Android | Device owner / dedicated |
|----------------------------|------------------|---------------------------|
| Full-screen, no app bar    | Yes              | Yes                       |
| Keep screen on             | Yes              | Yes                       |
| Back → no exit (5-tap exit)| Yes              | Yes                       |
| Block Home / Recent        | No               | Yes (when locked)         |
| Auto return to foreground  | No               | Possible                  |
| Block power button         | No               | No (system)               |
| Auto-start on boot         | Best-effort      | Configurable              |

We do not claim control that standard Android does not provide. For maximum kiosk control, use device owner or a dedicated-device deployment and configure lock task / kiosk there.
