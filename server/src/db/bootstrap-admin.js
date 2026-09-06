/**
 * The admin account this server cannot run without.
 *
 * `init.js` creates the `admins` table but leaves it empty, and nothing ever ran
 * `seed-admin.js` on its own. On the machine that was done by hand years ago, so it
 * was never missed - but the container keeps its database in the `db-data` volume,
 * which starts empty every time it is created. The tables were missing, 5050 died
 * with "no such table: tablets", and even once the tables existed the login that
 * lib/judge-proxy.ts performs against 5050 would have failed against an empty table.
 *
 * So: only when there is no admin at all. An existing row is never touched, and a
 * changed password is never overwritten - unlike `seed-admin.js`, which is INSERT OR
 * REPLACE and is still there for deliberately resetting the account.
 *
 * The credentials come from config, which reads ADMIN_USERNAME / ADMIN_PASSWORD.
 * Setting those in the environment is how this stops being admin/admin123 without
 * touching code.
 */

let bcrypt
try { bcrypt = require('bcrypt') } catch { bcrypt = require('bcryptjs') }
const path = require('path')
const Database = require('better-sqlite3')
const config = require('../config')

const dbPath = path.isAbsolute(config.databaseJudgesPath)
  ? config.databaseJudgesPath
  : path.join(process.cwd(), config.databaseJudgesPath)

try {
  const db = new Database(dbPath)
  const row = db.prepare('SELECT COUNT(*) AS n FROM admins').get()
  if (!row || row.n === 0) {
    const hash = bcrypt.hashSync(config.adminPassword, 10)
    db.prepare(
      "INSERT INTO admins (username, password_hash, updated_at) VALUES (?, ?, datetime('now'))",
    ).run(config.adminUsername, hash)
    console.log(`[JUDGE] No admin found — created "${config.adminUsername}".`)
  }
  db.close()
} catch (err) {
  // Never take the server down over this: a running 5050 with no admin is still
  // better than no 5050 at all, and the reason is on the log either way.
  console.error('[JUDGE] Could not ensure an admin account:', err.message)
}
