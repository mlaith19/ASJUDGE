const { getDb } = require('../db/connection');

class Settings {
  static get() {
    const db = getDb();
    return db.prepare('SELECT * FROM settings WHERE id = 1').get();
  }

  static update({ globalWebviewUrl, pollingIntervalSeconds, appTitle, environmentLabel }) {
    const db = getDb();
    return db.prepare(`
      UPDATE settings SET
        global_webview_url = ?,
        polling_interval_seconds = ?,
        app_title = ?,
        environment_label = ?,
        updated_at = CURRENT_TIMESTAMP
      WHERE id = 1
    `).run(globalWebviewUrl, pollingIntervalSeconds, appTitle, environmentLabel);
  }
}

module.exports = Settings;
