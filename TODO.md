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

## Known Gaps — Auth/Show-Isolation (post Stage 5)
_Note: these three items concern the **other** sub-project, `SCORING/v0-arabian-show-v-2-1-SOCEAL` (the Next.js scoring app), not this tablet-monitor backend. Recorded here because this is the only TODO.md in the repo tree. All were explicit, user-confirmed deferrals at the end of a 5-stage auth/show-isolation effort — not oversights._

- [x] ~~`GET /api/championship/session` still trusts a `?judge=` URL param for reads.~~ **RESOLVED** (post-Stage-5 security review, same day): fixed alongside a bigger related finding — the whole `/api/championship/*` family had no show_id/role checks at all. `session` GET now uses `lib/judge-session.ts`'s `requireJudgeForShow` and resolves `myNominations` from the verified session's own nickname, not the `?judge=` param.
- [ ] `lib/dsk-state.ts`'s `global.dskState` and `server.js`'s `global.judgeSocket`/`global.judgeServices` — deferred all the way back from Stage 1 of the isolation effort. These were found alongside `global.__rankScreenData`/`global.__screenData`/`lib/obs-manager.ts`'s singleton (all fixed in Stage 1 to be per-show-keyed) as the same class of global-in-memory-singleton bug — i.e. a second concurrent show could read/overwrite the first show's data through these globals. They were deliberately NOT bundled into that fix because they're tied to live WebSocket/ATEM-hardware and judge-tablet connections respectively, and need their own dedicated Discovery pass (confirm exactly what state they hold, who reads/writes them, whether the "one physical device" reasoning that exempted `lib/dsk-state.ts` from a fix actually applies) before deciding whether/how to fix them — not a small follow-on patch.
- [ ] No password-reset/forgot-password flow exists for any role. Stage 5 built real hashed-password login for admins, judges, and show-scoped users (via the real Users UI at `/shows/[showId]/users`), but there is no self-service or admin-assisted way to reset a forgotten password short of a developer manually rotating the hash in the DB. Needs to exist before this system is handed to real, non-technical users (judges, show staff) who will inevitably forget credentials.
