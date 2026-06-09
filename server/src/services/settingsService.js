const db = require('../db/connection');
const { isValidHttpUrl, sanitizeUrl } = require('../utils/urlValidator');

// Migration: add admin_tablet_alerts_enabled column if missing (for DBs created before this feature)
try {
  const cols = db.prepare("PRAGMA table_info('settings')").all();
  if (!cols.some((c) => c.name === 'admin_tablet_alerts_enabled')) {
    db.prepare("ALTER TABLE settings ADD COLUMN admin_tablet_alerts_enabled INTEGER DEFAULT 1").run();
  }
} catch (_) {}

function get() {
  const row = db.prepare('SELECT * FROM settings WHERE id = 1').get();
  if (row) {
    // Ensure new column has a sensible default when DB hasn't been migrated yet.
    if (row.admin_tablet_alerts_enabled == null) row.admin_tablet_alerts_enabled = 1;
    return row;
  }
  return {
    global_webview_url: '',
    polling_interval_seconds: 25,
    judge_release_timeout_seconds: 60,
    app_title: 'Tablet Monitor',
    environment_label: '',
    expected_wifi_ssid: '',
    kiosk_mode_enabled_default: 1,
    admin_tablet_alerts_enabled: 1,
    updated_at: null,
  };
}

function update(data) {
  const globalUrl = data.global_webview_url != null ? sanitizeUrl(String(data.global_webview_url)) : undefined;
  if (globalUrl !== undefined && globalUrl !== '' && !isValidHttpUrl(globalUrl)) {
    throw new Error('Invalid global_webview_url');
  }
  const interval = data.polling_interval_seconds != null
    ? Math.max(10, Math.min(300, parseInt(String(data.polling_interval_seconds), 10) || 25))
    : undefined;
  const timeoutSec = data.judge_release_timeout_seconds != null
    ? Math.max(15, Math.min(300, parseInt(String(data.judge_release_timeout_seconds), 10) || 60))
    : undefined;
  const appTitle = data.app_title != null ? String(data.app_title).trim().slice(0, 200) : undefined;
  const envLabel = data.environment_label != null ? String(data.environment_label).trim().slice(0, 100) : undefined;
  const expectedWifi = data.expected_wifi_ssid != null ? String(data.expected_wifi_ssid).trim().slice(0, 200) : undefined;
  let kioskRaw = data.kiosk_mode_enabled_default;
  if (Array.isArray(kioskRaw)) kioskRaw = kioskRaw[kioskRaw.length - 1];
  const kioskDefault = kioskRaw !== undefined && kioskRaw !== null
    ? (kioskRaw === true || kioskRaw === 1 || kioskRaw === '1' ? 1 : 0)
    : undefined;
  let alertsRaw = data.admin_tablet_alerts_enabled;
  if (Array.isArray(alertsRaw)) alertsRaw = alertsRaw[alertsRaw.length - 1];
  const adminTabletAlertsEnabled = alertsRaw !== undefined && alertsRaw !== null
    ? (alertsRaw === true || alertsRaw === 1 || alertsRaw === '1' ? 1 : 0)
    : undefined;

  const current = get();
  const global_webview_url = globalUrl !== undefined ? globalUrl : current.global_webview_url;
  const polling_interval_seconds = interval !== undefined ? interval : current.polling_interval_seconds;
  const judge_release_timeout_seconds = timeoutSec !== undefined ? timeoutSec : (current.judge_release_timeout_seconds != null ? current.judge_release_timeout_seconds : 60);
  const app_title = appTitle !== undefined ? appTitle : current.app_title;
  const environment_label = envLabel !== undefined ? envLabel : (current.environment_label || '');
  const expected_wifi_ssid = expectedWifi !== undefined ? expectedWifi : (current.expected_wifi_ssid || '');
  const kiosk_mode_enabled_default = kioskDefault !== undefined ? kioskDefault : (current.kiosk_mode_enabled_default != null ? current.kiosk_mode_enabled_default : 1);
  const admin_tablet_alerts_enabled = adminTabletAlertsEnabled !== undefined ? adminTabletAlertsEnabled : (current.admin_tablet_alerts_enabled != null ? current.admin_tablet_alerts_enabled : 1);

  db.prepare(`
    UPDATE settings SET
      global_webview_url = ?,
      polling_interval_seconds = ?,
      judge_release_timeout_seconds = ?,
      app_title = ?,
      environment_label = ?,
      expected_wifi_ssid = ?,
      kiosk_mode_enabled_default = ?,
      admin_tablet_alerts_enabled = ?,
      updated_at = datetime('now')
    WHERE id = 1
  `).run(global_webview_url, polling_interval_seconds, judge_release_timeout_seconds, app_title, environment_label, expected_wifi_ssid, kiosk_mode_enabled_default, admin_tablet_alerts_enabled);

  return get();
}

module.exports = { get, update };
