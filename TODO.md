# TODO – Next improvements

## Backend
- [ ] Replace seed admin with proper signup/change-password flow for production
- [ ] Add rate limiting on login and API endpoints
- [ ] Optional: migrate from SQLite to PostgreSQL (schema is already structured for easy migration)
- [ ] Add tablet_logs writes on register/heartbeat for audit trail
- [ ] Environment-based SESSION_SECRET and secure cookies in production

## Admin panel
- [ ] Bulk actions (e.g. set same URL for multiple tablets)
- [ ] Export tablets list (CSV)
- [ ] Dark/light theme toggle (currently dark)

## Flutter app
- [ ] Optional: hidden admin/debug panel (device ID, backend URL, target URL, battery, WiFi, IP, last sync) — only when kiosk is off or via secret gesture
- [ ] Android battery temperature via platform channel (BatteryManager) when needed
- [ ] Gateway IP and WiFi signal strength via Android platform channel if needed
- [ ] Configurable API base URL in app (e.g. from env or first-run field) instead of compile-time only
- [ ] Better offline handling: show “Waiting for server” and retry with backoff
- [ ] App version from pubspec or build number in heartbeat
- [ ] Optional: bring app to foreground when in kiosk and app goes to background (may require overlay permission or device owner)

## Operations
- [ ] HTTPS and proper host for production (reverse proxy)
- [ ] Backup strategy for SQLite DB and sessions
