/**
 * Migration: add cpu_usage to tablets (for heartbeat).
 * Run once: node src/db/migrate-add-cpu-usage.js
 */
const path = require('path');
const Database = require('better-sqlite3');
const config = require('../config');

const dbPath = path.isAbsolute(config.databaseTabletsPath)
  ? config.databaseTabletsPath
  : path.join(process.cwd(), config.databaseTabletsPath);
const db = new Database(dbPath);

function columnExists(table, col) {
  const row = db.prepare(`PRAGMA table_info(${table})`).all().find((c) => c.name === col);
  return !!row;
}

if (!columnExists('tablets', 'cpu_usage')) {
  db.exec('ALTER TABLE tablets ADD COLUMN cpu_usage INTEGER');
  console.log('tablets: added cpu_usage');
}

db.close();
console.log('migrate-add-cpu-usage done');
