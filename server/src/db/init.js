const path = require('path');
const fs = require('fs');
const Database = require('better-sqlite3');
const config = require('../config');

function resolvePath(p) {
  return path.isAbsolute(p) ? p : path.join(process.cwd(), p);
}

const tabletsPath = resolvePath(config.databaseTabletsPath);
const judgesPath = resolvePath(config.databaseJudgesPath);
const singleDb = path.normalize(tabletsPath) === path.normalize(judgesPath);

const dataDir = path.dirname(tabletsPath);
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });

if (singleDb) {
  const db = new Database(tabletsPath);
  db.exec(`
    CREATE TABLE IF NOT EXISTS admins (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS settings (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      global_webview_url TEXT DEFAULT '',
      polling_interval_seconds INTEGER DEFAULT 25,
      judge_release_timeout_seconds INTEGER DEFAULT 60,
      app_title TEXT DEFAULT 'Tablet Monitor',
      environment_label TEXT DEFAULT '',
      expected_wifi_ssid TEXT DEFAULT '',
      kiosk_mode_enabled_default INTEGER DEFAULT 1,
      updated_at TEXT DEFAULT (datetime('now'))
    );

    INSERT OR IGNORE INTO settings (id, global_webview_url, polling_interval_seconds, judge_release_timeout_seconds, app_title, environment_label, expected_wifi_ssid, kiosk_mode_enabled_default)
    VALUES (1, 'http://192.168.10.100', 25, 60, 'Tablet Monitor', 'Development', '', 1);

    CREATE TABLE IF NOT EXISTS tablets (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      device_id TEXT UNIQUE NOT NULL,
      judge_name TEXT DEFAULT '',
      judge_letter TEXT DEFAULT '',
      judge_color TEXT DEFAULT '',
      tablet_color TEXT DEFAULT '',
      tablet_label TEXT DEFAULT '',
      custom_webview_url TEXT,
      current_webview_url TEXT,
      battery_level INTEGER,
      battery_temperature REAL,
      cpu_usage INTEGER,
      charging INTEGER DEFAULT 0,
      wifi_ssid TEXT,
      wifi_bssid TEXT,
      ip_address TEXT,
      gateway TEXT,
      signal_strength INTEGER,
      wifi_frequency INTEGER,
      app_version TEXT,
      foreground_state TEXT,
      kiosk_mode_active INTEGER DEFAULT 0,
      screen_on INTEGER DEFAULT 0,
      connectivity_state TEXT,
      last_seen_at TEXT,
      is_online INTEGER DEFAULT 0,
      force_reload INTEGER DEFAULT 0,
      pending_action TEXT,
      pending_action_payload TEXT,
      pending_action_created_at TEXT,
      note TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_tablets_device_id ON tablets(device_id);
    CREATE INDEX IF NOT EXISTS idx_tablets_last_seen ON tablets(last_seen_at);
    CREATE INDEX IF NOT EXISTS idx_tablets_is_online ON tablets(is_online);
    CREATE INDEX IF NOT EXISTS idx_tablets_wifi_ssid ON tablets(wifi_ssid);

    CREATE TABLE IF NOT EXISTS tablet_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      tablet_id INTEGER NOT NULL,
      event_type TEXT NOT NULL,
      payload_json TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      FOREIGN KEY (tablet_id) REFERENCES tablets(id)
    );
    CREATE INDEX IF NOT EXISTS idx_tablet_logs_tablet_id ON tablet_logs(tablet_id);

    CREATE TABLE IF NOT EXISTS judges (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      judge_letter TEXT UNIQUE NOT NULL,
      judge_name TEXT DEFAULT '',
      judge_color TEXT DEFAULT '',
      username TEXT DEFAULT '',
      password TEXT DEFAULT '',
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_judges_letter ON judges(judge_letter);
  `);
  // Migration: add tablet_color column (stable palette key, assigned once at INSERT).
  try { db.exec("ALTER TABLE tablets ADD COLUMN tablet_color TEXT DEFAULT ''"); } catch (_) {}
  // Migration: add admin_tablet_alerts_enabled to settings.
  try { db.exec("ALTER TABLE settings ADD COLUMN admin_tablet_alerts_enabled INTEGER DEFAULT 1"); } catch (_) {}
  // Migration: add judge_type column (JUDGE, RG, DC, SPEAKER, SCREEN, ADMIN).
  try { db.exec("ALTER TABLE judges ADD COLUMN judge_type TEXT DEFAULT 'JUDGE'"); } catch (_) {}
  // Backfill: assign palette color to existing tablets that have none, ordered by id.
  const _PALETTE_KEYS = ['red','blue','green','orange','yellow','purple','pink','teal','cyan','lime','indigo','brown','gold','magenta','dark_blue'];
  const _needColor = db.prepare("SELECT id FROM tablets WHERE tablet_color IS NULL OR tablet_color = '' ORDER BY id ASC").all();
  const _assignColor = db.prepare("UPDATE tablets SET tablet_color = ? WHERE id = ?");
  _needColor.forEach((t, i) => _assignColor.run(_PALETTE_KEYS[i % _PALETTE_KEYS.length], t.id));
  if (_needColor.length > 0) console.log(`[TABLET_COLOR_BACKFILL] assigned colors to ${_needColor.length} tablets`);
  db.close();
  console.log('Database initialized (single file) at', config.databasePath);
} else {
  if (!fs.existsSync(path.dirname(judgesPath))) fs.mkdirSync(path.dirname(judgesPath), { recursive: true });

  const dbTablets = new Database(tabletsPath);
  dbTablets.exec(`
    CREATE TABLE IF NOT EXISTS tablets (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      device_id TEXT UNIQUE NOT NULL,
      judge_name TEXT DEFAULT '',
      judge_letter TEXT DEFAULT '',
      judge_color TEXT DEFAULT '',
      tablet_color TEXT DEFAULT '',
      tablet_label TEXT DEFAULT '',
      custom_webview_url TEXT,
      current_webview_url TEXT,
      battery_level INTEGER,
      battery_temperature REAL,
      cpu_usage INTEGER,
      charging INTEGER DEFAULT 0,
      wifi_ssid TEXT,
      wifi_bssid TEXT,
      ip_address TEXT,
      gateway TEXT,
      signal_strength INTEGER,
      wifi_frequency INTEGER,
      app_version TEXT,
      foreground_state TEXT,
      kiosk_mode_active INTEGER DEFAULT 0,
      screen_on INTEGER DEFAULT 0,
      connectivity_state TEXT,
      last_seen_at TEXT,
      is_online INTEGER DEFAULT 0,
      force_reload INTEGER DEFAULT 0,
      pending_action TEXT,
      pending_action_payload TEXT,
      pending_action_created_at TEXT,
      note TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_tablets_device_id ON tablets(device_id);
    CREATE INDEX IF NOT EXISTS idx_tablets_last_seen ON tablets(last_seen_at);
    CREATE INDEX IF NOT EXISTS idx_tablets_is_online ON tablets(is_online);
    CREATE INDEX IF NOT EXISTS idx_tablets_wifi_ssid ON tablets(wifi_ssid);

    CREATE TABLE IF NOT EXISTS tablet_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      tablet_id INTEGER NOT NULL,
      event_type TEXT NOT NULL,
      payload_json TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      FOREIGN KEY (tablet_id) REFERENCES tablets(id)
    );
    CREATE INDEX IF NOT EXISTS idx_tablet_logs_tablet_id ON tablet_logs(tablet_id);
  `);
  // Migration/backfill for older DBs.
  try { dbTablets.exec("ALTER TABLE tablets ADD COLUMN tablet_color TEXT DEFAULT ''"); } catch (_) {}
  const _PALETTE_KEYS2 = ['red','blue','green','orange','yellow','purple','pink','teal','cyan','lime','indigo','brown','gold','magenta','dark_blue'];
  const _needColor2 = dbTablets.prepare("SELECT id FROM tablets WHERE tablet_color IS NULL OR tablet_color = '' ORDER BY id ASC").all();
  const _assignColor2 = dbTablets.prepare("UPDATE tablets SET tablet_color = ? WHERE id = ?");
  _needColor2.forEach((t, i) => _assignColor2.run(_PALETTE_KEYS2[i % _PALETTE_KEYS2.length], t.id));
  dbTablets.close();

  const dbJudges = new Database(judgesPath);
  dbJudges.exec(`
    CREATE TABLE IF NOT EXISTS admins (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS settings (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      global_webview_url TEXT DEFAULT '',
      polling_interval_seconds INTEGER DEFAULT 25,
      judge_release_timeout_seconds INTEGER DEFAULT 60,
      app_title TEXT DEFAULT 'Tablet Monitor',
      environment_label TEXT DEFAULT '',
      expected_wifi_ssid TEXT DEFAULT '',
      kiosk_mode_enabled_default INTEGER DEFAULT 1,
      updated_at TEXT DEFAULT (datetime('now'))
    );
    INSERT OR IGNORE INTO settings (id, global_webview_url, polling_interval_seconds, judge_release_timeout_seconds, app_title, environment_label, expected_wifi_ssid, kiosk_mode_enabled_default)
    VALUES (1, 'http://192.168.10.100', 25, 60, 'Tablet Monitor', 'Development', '', 1);
    CREATE TABLE IF NOT EXISTS judges (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      judge_letter TEXT UNIQUE NOT NULL,
      judge_name TEXT DEFAULT '',
      judge_color TEXT DEFAULT '',
      judge_type TEXT DEFAULT 'JUDGE',
      username TEXT DEFAULT '',
      password TEXT DEFAULT '',
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_judges_letter ON judges(judge_letter);
  `);
  try { dbJudges.exec("ALTER TABLE settings ADD COLUMN admin_tablet_alerts_enabled INTEGER DEFAULT 1"); } catch (_) {}
  try { dbJudges.exec("ALTER TABLE judges ADD COLUMN judge_type TEXT DEFAULT 'JUDGE'"); } catch (_) {}
  dbJudges.close();
  console.log('Tablets DB at', config.databaseTabletsPath);
  console.log('Judges DB at', config.databaseJudgesPath);
}
