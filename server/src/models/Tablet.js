const { getDb } = require('../db/connection');
const config = require('../config');

class Tablet {
  static findAll() {
    const db = getDb();
    return db.prepare('SELECT * FROM tablets ORDER BY last_seen_at DESC').all();
  }

  static findById(id) {
    const db = getDb();
    return db.prepare('SELECT * FROM tablets WHERE id = ?').get(id);
  }

  static findByDeviceId(deviceId) {
    const db = getDb();
    return db.prepare('SELECT * FROM tablets WHERE device_id = ?').get(deviceId);
  }

  static register({ deviceId, judgeName, tabletLabel, ipAddress, appVersion }) {
    const db = getDb();
    const existing = this.findByDeviceId(deviceId);
    if (existing) {
      db.prepare(`
        UPDATE tablets SET
          judge_name = COALESCE(?, judge_name),
          tablet_label = COALESCE(?, tablet_label),
          ip_address = COALESCE(?, ip_address),
          app_version = COALESCE(?, app_version),
          last_seen_at = CURRENT_TIMESTAMP,
          is_online = 1,
          updated_at = CURRENT_TIMESTAMP
        WHERE device_id = ?
      `).run(judgeName, tabletLabel, ipAddress, appVersion, deviceId);
      return this.findByDeviceId(deviceId);
    }

    db.prepare(`
      INSERT INTO tablets (device_id, judge_name, tablet_label, ip_address, app_version, last_seen_at, is_online)
      VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP, 1)
    `).run(deviceId, judgeName || '', tabletLabel || '', ipAddress || '', appVersion || '');
    return this.findByDeviceId(deviceId);
  }

  static heartbeat({ deviceId, judgeName, tabletLabel, batteryLevel, batteryTemperature, charging, ipAddress, appVersion, currentWebviewUrl }) {
    const db = getDb();
    const result = db.prepare(`
      UPDATE tablets SET
        judge_name = COALESCE(?, judge_name),
        tablet_label = COALESCE(?, tablet_label),
        battery_level = ?,
        battery_temperature = ?,
        charging = ?,
        ip_address = COALESCE(?, ip_address),
        app_version = COALESCE(?, app_version),
        current_webview_url = COALESCE(?, current_webview_url),
        last_seen_at = CURRENT_TIMESTAMP,
        is_online = 1,
        updated_at = CURRENT_TIMESTAMP
      WHERE device_id = ?
    `).run(
      judgeName, tabletLabel,
      batteryLevel ?? null, batteryTemperature ?? null, charging ? 1 : 0,
      ipAddress, appVersion, currentWebviewUrl,
      deviceId
    );
    return result.changes > 0;
  }

  static getConfig(deviceId) {
    const db = getDb();
    const tablet = this.findByDeviceId(deviceId);
    if (!tablet) return null;

    const settings = db.prepare('SELECT * FROM settings WHERE id = 1').get();
    const targetUrl = tablet.custom_webview_url || settings.global_webview_url;

    return {
      targetWebviewUrl: targetUrl,
      judgeName: tablet.judge_name,
      tabletLabel: tablet.tablet_label,
      pollingIntervalSeconds: settings.polling_interval_seconds,
      forceReload: tablet.force_reload === 1,
      appTitle: settings.app_title,
    };
  }

  static clearForceReload(deviceId) {
    const db = getDb();
    db.prepare('UPDATE tablets SET force_reload = 0, updated_at = CURRENT_TIMESTAMP WHERE device_id = ?').run(deviceId);
  }

  static update(id, { judgeName, tabletLabel, customWebviewUrl, note }) {
    const db = getDb();
    return db.prepare(`
      UPDATE tablets SET
        judge_name = ?,
        tablet_label = ?,
        custom_webview_url = ?,
        note = ?,
        updated_at = CURRENT_TIMESTAMP
      WHERE id = ?
    `).run(judgeName, tabletLabel, customWebviewUrl || null, note || '', id);
  }

  static setForceReload(id) {
    const db = getDb();
    return db.prepare('UPDATE tablets SET force_reload = 1, updated_at = CURRENT_TIMESTAMP WHERE id = ?').run(id);
  }

  static updateOnlineStatus() {
    const db = getDb();
    const threshold = config.onlineThresholdSeconds;
    db.prepare(`
      UPDATE tablets SET
        is_online = CASE
          WHEN last_seen_at IS NOT NULL
            AND (strftime('%s','now') - strftime('%s', last_seen_at)) <= ?
          THEN 1 ELSE 0
        END
    `).run(threshold);
  }

  static search({ query, status, lowBattery }) {
    const db = getDb();
    let sql = 'SELECT * FROM tablets WHERE 1=1';
    const params = [];

    if (query) {
      sql += ' AND (judge_name LIKE ? OR device_id LIKE ? OR tablet_label LIKE ?)';
      const q = `%${query}%`;
      params.push(q, q, q);
    }
    if (status === 'online') {
      sql += ' AND is_online = 1';
    } else if (status === 'offline') {
      sql += ' AND is_online = 0';
    }
    if (lowBattery) {
      sql += ' AND battery_level IS NOT NULL AND battery_level <= 20';
    }

    sql += ' ORDER BY last_seen_at DESC';
    return db.prepare(sql).all(...params);
  }
}

module.exports = Tablet;
