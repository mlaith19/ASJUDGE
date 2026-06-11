let bcrypt; try { bcrypt = require('bcrypt'); } catch { bcrypt = require('bcryptjs'); }
const db = require('../db/connection');

function findByUsername(username) {
  const row = db.prepare('SELECT * FROM admins WHERE username = ?').get(username);
  return row || null;
}

async function verifyPassword(username, password) {
  const admin = findByUsername(username);
  if (!admin) return null;
  const ok = await bcrypt.compare(password, admin.password_hash);
  return ok ? admin : null;
}

module.exports = { findByUsername, verifyPassword };
