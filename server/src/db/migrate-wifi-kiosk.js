/**
 * Migration: add WiFi, gateway, kiosk, foreground, screen state columns.
 * Run once: node src/db/migrate-wifi-kiosk.js
 * Safe to run multiple times (checks for column existence).
 */
const path = require('path');
const Database = require('better-sqlite3');
const config = require('../config');

const dbPath = path.isAbsolute(config.databasePath)
  ? config.databasePath
  : path.join(process.cwd(), config.databasePath);
const db = new Database(dbPath);

function columnExists(table, col) {
  const row = db.prepare(`PRAGMA table_info(${table})`).all().find((c) => c.name === col);
  return !!row;
}
function tableExists(table) {
  const row = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?").get(table);
  return !!row;
}

// Judges table (master list of judges)
if (!tableExists('judges')) {
  db.exec(`
    CREATE TABLE judges (
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
  console.log('created table judges');
} else {
  if (!columnExists('judges', 'username')) {
    db.exec('ALTER TABLE judges ADD COLUMN username TEXT DEFAULT ""');
    console.log('judges: added username');
  }
  if (!columnExists('judges', 'password')) {
    db.exec('ALTER TABLE judges ADD COLUMN password TEXT DEFAULT ""');
    console.log('judges: added password');
  }
}

// Settings: expected_wifi_ssid, kiosk_mode_enabled_default
if (!columnExists('settings', 'expected_wifi_ssid')) {
  db.exec('ALTER TABLE settings ADD COLUMN expected_wifi_ssid TEXT DEFAULT ""');
  console.log('settings: added expected_wifi_ssid');
}
if (!columnExists('settings', 'kiosk_mode_enabled_default')) {
  db.exec('ALTER TABLE settings ADD COLUMN kiosk_mode_enabled_default INTEGER DEFAULT 1');
  console.log('settings: added kiosk_mode_enabled_default');
}

// Tablets: judge_letter
if (!columnExists('tablets', 'judge_letter')) {
  db.exec('ALTER TABLE tablets ADD COLUMN judge_letter TEXT DEFAULT ""');
  console.log('tablets: added judge_letter');
}

// Tablets: pending_action, pending_action_payload, pending_action_created_at
if (!columnExists('tablets', 'pending_action')) {
  db.exec('ALTER TABLE tablets ADD COLUMN pending_action TEXT');
  console.log('tablets: added pending_action');
}
if (!columnExists('tablets', 'pending_action_payload')) {
  db.exec('ALTER TABLE tablets ADD COLUMN pending_action_payload TEXT');
  console.log('tablets: added pending_action_payload');
}
if (!columnExists('tablets', 'pending_action_created_at')) {
  db.exec('ALTER TABLE tablets ADD COLUMN pending_action_created_at TEXT');
  console.log('tablets: added pending_action_created_at');
}

// Tablets: judge_color
if (!columnExists('tablets', 'judge_color')) {
  db.exec('ALTER TABLE tablets ADD COLUMN judge_color TEXT DEFAULT ""');
  console.log('tablets: added judge_color');
}

// Tablets: wifi_ssid, wifi_bssid, gateway, signal_strength, wifi_frequency, foreground_state, kiosk_mode_active, screen_on, connectivity_state
const tabletCols = [
  ['wifi_ssid', 'TEXT'],
  ['wifi_bssid', 'TEXT'],
  ['gateway', 'TEXT'],
  ['signal_strength', 'INTEGER'],
  ['wifi_frequency', 'INTEGER'],
  ['foreground_state', 'TEXT'],
  ['kiosk_mode_active', 'INTEGER'],
  ['screen_on', 'INTEGER'],
  ['connectivity_state', 'TEXT'],
];
for (const [col, typ] of tabletCols) {
  if (!columnExists('tablets', col)) {
    db.exec(`ALTER TABLE tablets ADD COLUMN ${col} ${typ}`);
    console.log('tablets: added', col);
  }
}

db.close();
console.log('Migration done.');
