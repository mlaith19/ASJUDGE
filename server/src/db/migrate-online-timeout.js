/**
 * Migration: add judge_release_timeout_seconds to settings (online/offline heartbeat timeout).
 * Run once: node src/db/migrate-online-timeout.js
 */
const path = require('path');
const Database = require('better-sqlite3');
const config = require('../config');

const dbPath = path.isAbsolute(config.databaseJudgesPath)
  ? config.databaseJudgesPath
  : path.join(process.cwd(), config.databaseJudgesPath);
const db = new Database(dbPath);

function columnExists(table, col) {
  const row = db.prepare(`PRAGMA table_info(${table})`).all().find((c) => c.name === col);
  return !!row;
}

if (!columnExists('settings', 'judge_release_timeout_seconds')) {
  db.exec('ALTER TABLE settings ADD COLUMN judge_release_timeout_seconds INTEGER DEFAULT 60');
  db.prepare('UPDATE settings SET judge_release_timeout_seconds = 60 WHERE id = 1').run();
  console.log('settings: added judge_release_timeout_seconds (default 60)');
}

console.log('migrate-online-timeout done');
