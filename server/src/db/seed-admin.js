const bcrypt = require('bcrypt');
const Database = require('better-sqlite3');
const config = require('../config');
const path = require('path');

const dbPath = path.isAbsolute(config.databaseJudgesPath)
  ? config.databaseJudgesPath
  : path.join(process.cwd(), config.databaseJudgesPath);

const db = new Database(dbPath);

const DEV_USERNAME = 'admin';
const DEV_PASSWORD = 'admin123';

async function seed() {
  const hash = await bcrypt.hash(DEV_PASSWORD, 10);
  const stmt = db.prepare(`
    INSERT OR REPLACE INTO admins (id, username, password_hash, updated_at)
    VALUES (1, ?, ?, datetime('now'))
  `);
  stmt.run(DEV_USERNAME, hash);
  db.close();
  console.log('Development admin user created.');
  console.log('  Username:', DEV_USERNAME);
  console.log('  Password:', DEV_PASSWORD);
  console.log('  ⚠️  DEVELOPMENT ONLY - change in production!');
}

seed().catch((err) => {
  console.error(err);
  process.exit(1);
});
