const { getDb } = require('../db/connection');

class Admin {
  static findByUsername(username) {
    const db = getDb();
    return db.prepare('SELECT * FROM admins WHERE username = ?').get(username);
  }

  static findById(id) {
    const db = getDb();
    return db.prepare('SELECT id, username, created_at FROM admins WHERE id = ?').get(id);
  }

  static updatePassword(id, passwordHash) {
    const db = getDb();
    return db.prepare('UPDATE admins SET password_hash = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?').run(passwordHash, id);
  }
}

module.exports = Admin;
