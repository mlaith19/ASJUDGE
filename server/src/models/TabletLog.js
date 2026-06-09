const { getDb } = require('../db/connection');

class TabletLog {
  static create(tabletId, eventType, payload = {}) {
    const db = getDb();
    return db.prepare(
      'INSERT INTO tablet_logs (tablet_id, event_type, payload_json) VALUES (?, ?, ?)'
    ).run(tabletId, eventType, JSON.stringify(payload));
  }

  static findByTabletId(tabletId, limit = 50) {
    const db = getDb();
    return db.prepare(
      'SELECT * FROM tablet_logs WHERE tablet_id = ? ORDER BY created_at DESC LIMIT ?'
    ).all(tabletId, limit);
  }
}

module.exports = TabletLog;
