require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const bcrypt = require('bcrypt');
const config = require('../config');

require('./init');
const conn = require('./connection');
const db = conn.db || conn.dbJudges || conn;

async function seed() {
  const existing = db.prepare('SELECT id FROM admins WHERE username = ?').get(config.adminUsername);
  if (existing) {
    console.log(`Admin user "${config.adminUsername}" already exists. Skipping seed.`);
    return;
  }

  const hash = await bcrypt.hash(config.adminPassword, 12);
  db.prepare('INSERT INTO admins (username, password_hash) VALUES (?, ?)').run(config.adminUsername, hash);
  console.log(`Admin user "${config.adminUsername}" created successfully.`);
  console.log(`  Username: ${config.adminUsername}`);
  console.log(`  Password: ${config.adminPassword}`);
  console.log('  ⚠ Change these credentials in production!');
}

seed().catch(err => {
  console.error('Seed failed:', err);
  process.exit(1);
});
