const conn = require('../db/connection');
const db = conn.dbTablets || conn;
const config = require('../config');
const { isValidHttpUrl, sanitizeUrl } = require('../utils/urlValidator');
const { sanitizeString } = require('../utils/sanitize');
const { isValidKey } = require('../constants/judgeColors');

const ONLINE_THRESHOLD_MS = (config.onlineThresholdSeconds || 60) * 1000;
const TABLET_COLOR_KEYS = ['red', 'blue', 'green', 'orange', 'yellow', 'purple', 'pink', 'teal', 'cyan', 'lime', 'indigo', 'brown', 'gold', 'magenta', 'dark_blue'];

function ensureTabletColorColumn() {
  try {
    const cols = db.prepare("PRAGMA table_info('tablets')").all();
    const hasTabletColor = Array.isArray(cols) && cols.some((c) => String(c.name || '').toLowerCase() === 'tablet_color');
    if (!hasTabletColor) {
      db.exec("ALTER TABLE tablets ADD COLUMN tablet_color TEXT DEFAULT ''");
      console.log('[TABLET_COLOR_MIGRATION]=added tablet_color column');
    }
    // Assign colors to tablets that have none yet
    const rows = db.prepare("SELECT id FROM tablets WHERE tablet_color IS NULL OR TRIM(tablet_color) = '' ORDER BY id ASC").all();
    const upd = db.prepare("UPDATE tablets SET tablet_color = ?, updated_at = datetime('now') WHERE id = ?");
    rows.forEach((r, i) => upd.run(TABLET_COLOR_KEYS[i % TABLET_COLOR_KEYS.length] || 'red', r.id));

    // Fix tablets that all share the same color (caused by the registration bug
    // where every new tablet was inserted with TABLET_COLOR_KEYS[0]='red').
    const all = db.prepare("SELECT id, tablet_color FROM tablets ORDER BY id ASC").all();
    if (all.length > 1) {
      const colors = all.map((t) => (t.tablet_color || '').trim().toLowerCase());
      const allSame = colors.every((c) => c === colors[0]);
      const hasDups = allSame || colors.some((c, i) => colors.indexOf(c) !== i);
      if (hasDups) {
        const fix = db.prepare("UPDATE tablets SET tablet_color = ?, updated_at = datetime('now') WHERE id = ?");
        all.forEach((r, i) => fix.run(TABLET_COLOR_KEYS[i % TABLET_COLOR_KEYS.length] || 'red', r.id));
        console.log(`[TABLET_COLOR_FIX]=reassigned colors for ${all.length} tablets`);
      }
    }
  } catch (e) {
    console.log(`[TABLET_COLOR_MIGRATION_ERROR]=${e.message}`);
  }
}

ensureTabletColorColumn();

function updateOnlineStatus() {
  const cutoff = new Date(Date.now() - ONLINE_THRESHOLD_MS).toISOString();
  db.prepare('UPDATE tablets SET is_online = 0 WHERE last_seen_at < ?').run(cutoff);
  db.prepare('UPDATE tablets SET is_online = 1 WHERE last_seen_at >= ?').run(cutoff);
}

function findByDeviceId(deviceId) {
  return db.prepare('SELECT * FROM tablets WHERE device_id = ?').get(deviceId) || null;
}

function findById(id) {
  return db.prepare('SELECT * FROM tablets WHERE id = ?').get(id) || null;
}

function list(filters = {}) {
  updateOnlineStatus();
  let sql = 'SELECT * FROM tablets WHERE 1=1';
  const params = [];

  if (filters.search) {
    sql += ' AND (judge_name LIKE ? OR judge_letter LIKE ? OR tablet_label LIKE ? OR device_id LIKE ?)';
    const term = `%${sanitizeString(filters.search, 100)}%`;
    params.push(term, term, term, term);
  }
  if (filters.judgeLetter) {
    sql += ' AND judge_letter = ?';
    params.push(sanitizeString(filters.judgeLetter, 10));
  }
  if (filters.status === 'online') {
    sql += " AND last_seen_at >= datetime('now', ?)";
    params.push(`-${config.onlineThresholdSeconds} seconds`);
  } else if (filters.status === 'offline') {
    sql += " AND (last_seen_at < datetime('now', ?) OR last_seen_at IS NULL)";
    params.push(`-${config.onlineThresholdSeconds} seconds`);
  }
  if (filters.lowBattery) {
    sql += ' AND battery_level IS NOT NULL AND battery_level < 20';
  }
  if (filters.wifiSsid) {
    sql += ' AND wifi_ssid LIKE ?';
    params.push(`%${sanitizeString(filters.wifiSsid, 100)}%`);
  }
  if (filters.wrongNetwork) {
    const expected = (require('./settingsService').get().expected_wifi_ssid || '').trim();
    if (expected) {
      sql += ' AND (wifi_ssid IS NULL OR wifi_ssid != ? OR wifi_ssid = "")';
      params.push(expected);
    }
  }

  sql += ' ORDER BY is_online DESC, last_seen_at IS NULL, last_seen_at DESC';
  return db.prepare(sql).all(...params);
}

function clearOldJudgeAssignmentForOtherTablets(judgeLetter, currentDeviceId) {
  const norm = sanitizeString(String(judgeLetter || '').trim().toUpperCase(), 10);
  const current = sanitizeString(String(currentDeviceId || '').trim(), 200);
  if (!norm || !current) return;
  const before = db.prepare(`
    SELECT id, device_id, judge_letter, judge_name, judge_color
    FROM tablets
    WHERE UPPER(TRIM(COALESCE(judge_letter, ''))) = ?
      AND device_id != ?
    ORDER BY updated_at DESC, id DESC
  `).all(norm, current);
  if (!before || before.length === 0) return;
  console.log(`[JUDGES_ASSIGNMENT_BEFORE]=${JSON.stringify({ judgeLetter: norm, currentDeviceId: current, oldAssignments: before })}`);
  db.prepare(`
    UPDATE tablets SET
      judge_letter = NULL,
      judge_name = NULL,
      judge_color = NULL,
      updated_at = datetime('now')
    WHERE UPPER(TRIM(COALESCE(judge_letter, ''))) = ?
      AND device_id != ?
  `).run(norm, current);
  console.log(`[OLD_JUDGE_CLEARED]=${JSON.stringify({ judgeLetter: norm, clearedCount: before.length, currentDeviceId: current })}`);
  const after = db.prepare(`
    SELECT id, device_id, judge_letter
    FROM tablets
    WHERE UPPER(TRIM(COALESCE(judge_letter, ''))) = ?
    ORDER BY updated_at DESC, id DESC
  `).all(norm);
  console.log(`[JUDGES_ASSIGNMENT_AFTER]=${JSON.stringify({ judgeLetter: norm, assignments: after })}`);
}

function getTabletColorByIdOrder(tabletId) {
  const fullListById = list({}).sort((a, b) => (Number(a.id) || 0) - (Number(b.id) || 0));
  const index = fullListById.findIndex((t) => Number(t.id) === Number(tabletId));
  return index >= 0 ? (TABLET_COLOR_KEYS[index % TABLET_COLOR_KEYS.length] || 'red') : (TABLET_COLOR_KEYS[0] || 'red');
}

function ensureTabletColorPersisted(deviceId) {
  const tab = findByDeviceId(deviceId);
  if (!tab) return null;
  const current = (tab.tablet_color || '').toString().trim().toLowerCase();
  if (current) return current;
  const colorKey = getTabletColorByIdOrder(tab.id);
  db.prepare("UPDATE tablets SET tablet_color = ?, updated_at = datetime('now') WHERE id = ?").run(colorKey, tab.id);
  return colorKey;
}

function register(payload) {
  const deviceId = sanitizeString(payload.deviceId || payload.device_id, 200);
  if (!deviceId) throw new Error('deviceId required');

  const judgeLetterRaw = payload.judgeLetter ?? payload.judge_letter;
  const judgeLetter = judgeLetterRaw ? sanitizeString(String(judgeLetterRaw).trim().toUpperCase(), 10) : '';
  const tabletLabel = sanitizeString(payload.tabletLabel || payload.tablet_label, 200);

  let judgeName = '';
  if (judgeLetter && judgeLetter !== '__ADMIN__') {
    const judgesService = require('./judgesService');
    const judge = judgesService.getByLetter(judgeLetter);
    if (!judge) throw new Error(`Judge letter "${judgeLetter}" not found. Create the judge in Admin → Judges first.`);
    judgeName = judge.judge_name || '';
  }

  const existing = findByDeviceId(deviceId);
  if (existing) {
    const oldJudgeLetter = (existing.judge_letter || '').toString().trim().toUpperCase();
    // When tablet registers with empty judgeLetter (e.g. from Setup screen), keep existing assignment so it still appears in Control.
    const finalJudgeLetter = judgeLetter ? (judgeLetter || null) : (existing.judge_letter || null);
    const finalJudgeName = judgeLetter ? (judgeName || null) : (existing.judge_name || null);
    const newJudgeLetter = (finalJudgeLetter || '').toString().trim().toUpperCase();
    console.log(`[DEVICE_ID]=${deviceId}`);
    console.log(`[OLD_JUDGE_LETTER]=${oldJudgeLetter}`);
    console.log(`[NEW_JUDGE_LETTER]=${newJudgeLetter}`);
    console.log(`[OLD_JUDGE]=${oldJudgeLetter}`);
    console.log(`[NEW_JUDGE]=${newJudgeLetter}`);
    if (finalJudgeLetter) clearOldJudgeAssignmentForOtherTablets(finalJudgeLetter, deviceId);
    db.prepare(`
      UPDATE tablets SET
        judge_name = COALESCE(?, judge_name),
        judge_letter = ?,
        judge_color = NULL,
        tablet_label = COALESCE(?, tablet_label),
        updated_at = datetime('now')
      WHERE device_id = ?
    `).run(finalJudgeName, finalJudgeLetter, tabletLabel || existing.tablet_label, deviceId);
    console.log(`[SERVER_ASSIGNMENT_UPDATED]=${JSON.stringify({ deviceId, oldJudgeLetter, newJudgeLetter })}`);
    console.log('[UPDATED]=TRUE');
    const tabletColor = ensureTabletColorPersisted(deviceId);
    console.log(`[NEW_JUDGE_ASSIGNED]=${JSON.stringify({ deviceId, judgeLetter: finalJudgeLetter || '', judgeName: finalJudgeName || '', tabletColor: tabletColor || '' })}`);
    return findByDeviceId(deviceId);
  }

  if (judgeLetter) clearOldJudgeAssignmentForOtherTablets(judgeLetter, deviceId);
  db.prepare(`
    INSERT INTO tablets (device_id, judge_name, judge_letter, judge_color, tablet_color, tablet_label)
    VALUES (?, ?, ?, NULL, NULL, ?)
  `).run(deviceId, judgeName || null, judgeLetter || null, tabletLabel || '');
  const tabletColor = ensureTabletColorPersisted(deviceId);
  console.log(`[NEW_JUDGE_ASSIGNED]=${JSON.stringify({ deviceId, judgeLetter: judgeLetter || '', judgeName: judgeName || '', tabletColor: tabletColor || '' })}`);
  return findByDeviceId(deviceId);
}

function heartbeat(deviceId, payload) {
  const tablet = findByDeviceId(deviceId);
  if (!tablet) throw new Error('Tablet not registered');

  const oldJudgeLetter = (tablet.judge_letter || '').toString().trim().toUpperCase();
  const rawJudgeLetter = payload.judgeLetter ?? payload.judge_letter;
  const judgeLetter = rawJudgeLetter && String(rawJudgeLetter).trim()
    ? sanitizeString(String(rawJudgeLetter).trim().toUpperCase(), 10)
    : (tablet.judge_letter || '');
  let judgeName = tablet.judge_name || '';
  if (judgeLetter) {
    const judgesService = require('./judgesService');
    const judge = judgesService.getByLetter(judgeLetter);
    if (judge) {
      judgeName = judge.judge_name || '';
    }
  }
  const tabletLabel = sanitizeString(payload.tabletLabel ?? payload.tablet_label ?? tablet.tablet_label, 200);
  const batteryLevel = payload.batteryLevel ?? payload.battery_level;
  const _parsedBattery = batteryLevel != null ? parseInt(String(batteryLevel), 10) : NaN;
  const numBattery = !Number.isNaN(_parsedBattery) ? Math.min(100, Math.max(0, _parsedBattery)) : null;
  const batteryTemp = payload.batteryTemperature ?? payload.battery_temperature;
  const _parsedTemp = batteryTemp != null ? parseFloat(String(batteryTemp)) : NaN;
  const temp = !Number.isNaN(_parsedTemp) ? _parsedTemp : null;
  const cpuUsage = payload.cpuUsage ?? payload.cpu_usage;
  const _parsedCpu = cpuUsage != null ? parseInt(String(cpuUsage), 10) : NaN;
  const cpuUsageNum = !Number.isNaN(_parsedCpu) ? Math.min(100, Math.max(0, _parsedCpu)) : null;
  const charging = payload.charging === true || payload.charging === 1 ? 1 : 0;
  const ipAddress = sanitizeString(payload.ipAddress ?? payload.ip_address, 50);
  const appVersion = sanitizeString(payload.appVersion ?? payload.app_version, 50);
  const currentWebviewUrl = sanitizeString(payload.currentWebviewUrl ?? payload.current_webview_url, 2048);
  const wifiSsid = sanitizeString(payload.wifiSSID ?? payload.wifi_ssid, 200);
  const wifiBssid = sanitizeString(payload.wifiBSSID ?? payload.wifi_bssid, 100);
  const gateway = sanitizeString(payload.gateway, 50);
  const signalStrength = payload.signalStrength ?? payload.signal_strength;
  const _parsedSig = signalStrength != null ? parseInt(String(signalStrength), 10) : NaN;
  const sigNum = !Number.isNaN(_parsedSig) ? _parsedSig : null;
  const wifiFreq = payload.wifiFrequency ?? payload.wifi_frequency;
  const _parsedFreq = wifiFreq != null ? parseInt(String(wifiFreq), 10) : NaN;
  const freqNum = !Number.isNaN(_parsedFreq) ? _parsedFreq : null;
  const foregroundState = sanitizeString(payload.foregroundState ?? payload.foreground_state, 50);
  const kioskModeActive = payload.kioskModeActive === true || payload.kioskModeActive === 1 ? 1 : 0;
  const screenOn = payload.screenOn === true || payload.screenOn === 1 ? 1 : 0;
  const connectivityState = sanitizeString(payload.connectivityState ?? payload.connectivity_state, 50);

  console.log(`[DEVICE_ID]=${deviceId}`);
  console.log(`[OLD_JUDGE_LETTER]=${oldJudgeLetter}`);
  console.log(`[NEW_JUDGE_LETTER]=${judgeLetter}`);
  console.log(`[OLD_JUDGE]=${oldJudgeLetter}`);
  console.log(`[NEW_JUDGE]=${judgeLetter}`);
  if (judgeLetter) clearOldJudgeAssignmentForOtherTablets(judgeLetter, deviceId);
  const stmt = db.prepare(`
    UPDATE tablets SET
      judge_name = ?,
      judge_letter = ?,
      judge_color = NULL,
      tablet_label = ?,
      battery_level = ?,
      battery_temperature = ?,
      cpu_usage = ?,
      charging = ?,
      ip_address = ?,
      app_version = ?,
      current_webview_url = ?,
      wifi_ssid = ?,
      wifi_bssid = ?,
      gateway = ?,
      signal_strength = ?,
      wifi_frequency = ?,
      foreground_state = ?,
      kiosk_mode_active = ?,
      screen_on = ?,
      connectivity_state = ?,
      last_seen_at = datetime('now'),
      is_online = 1,
      updated_at = datetime('now')
    WHERE device_id = ?
  `);
  stmt.run(
    judgeName, judgeLetter, tabletLabel, numBattery, temp, cpuUsageNum, charging, ipAddress || null, appVersion || null, currentWebviewUrl || null,
    wifiSsid || null, wifiBssid || null, gateway || null, sigNum, freqNum,
    foregroundState || null, kioskModeActive, screenOn, connectivityState || null,
    deviceId,
  );
  console.log(`[SERVER_ASSIGNMENT_UPDATED]=${JSON.stringify({ deviceId, oldJudgeLetter, newJudgeLetter: judgeLetter })}`);
  console.log('[UPDATED]=TRUE');
  const tabletColor = ensureTabletColorPersisted(deviceId);
  console.log(`[NEW_JUDGE_ASSIGNED]=${JSON.stringify({ deviceId, judgeLetter: judgeLetter || '', judgeName: judgeName || '', tabletColor: tabletColor || '' })}`);

  return findByDeviceId(deviceId);
}

function getConfig(deviceId) {
  const settings = require('./settingsService').get();
  const tablet = findByDeviceId(deviceId);
  if (!tablet) throw new Error('Tablet not registered');

  const targetWebviewUrl = (tablet.custom_webview_url && tablet.custom_webview_url.trim() !== '')
    ? tablet.custom_webview_url.trim()
    : (settings.global_webview_url && settings.global_webview_url.trim() !== ''
      ? settings.global_webview_url.trim()
      : '');

  const forceReload = !!tablet.force_reload;
  if (forceReload) {
    db.prepare("UPDATE tablets SET force_reload = 0, updated_at = datetime('now') WHERE device_id = ?").run(deviceId);
  }

  const kioskDefault = settings.kiosk_mode_enabled_default != null ? !!settings.kiosk_mode_enabled_default : true;
  const expectedWifi = (settings.expected_wifi_ssid || '').trim();

  const pendingAction = (tablet.pending_action || '').trim();
  const pendingActionPayload = (tablet.pending_action_payload || '').trim();

  const judgesService = require('./judgesService');
  const judgeRecord = tablet.judge_letter ? judgesService.getByLetter(tablet.judge_letter) : null;
  const judgeUsername = judgeRecord ? (judgeRecord.username || '') : '';
  const judgePassword = judgeRecord ? (judgeRecord.password || '') : '';

  const tabletDisplayColor = ensureTabletColorPersisted(deviceId) || 'red';

  return {
    targetWebviewUrl,
    judgeName: tablet.judge_name || '',
    judgeLetter: tablet.judge_letter || '',
    judgeColor: '',
    tablet_color: tabletDisplayColor,
    tabletColor: tabletDisplayColor,
    tabletDisplayColor,
    judgeUsername,
    judgePassword,
    tabletLabel: tablet.tablet_label || '',
    pollingIntervalSeconds: settings.polling_interval_seconds || 25,
    forceReload,
    kioskModeEnabled: kioskDefault,
    keepScreenOn: true,
    expectedWifiSSID: expectedWifi || undefined,
    pendingAction: pendingAction || undefined,
    pendingActionPayload: pendingActionPayload || undefined,
    adminTabletAlertsEnabled: settings.admin_tablet_alerts_enabled != null ? settings.admin_tablet_alerts_enabled !== 0 : true,
  };
}

function setPendingAction(tabletId, action, payload) {
  const tablet = findById(tabletId);
  if (!tablet) throw new Error('Tablet not found');
  const normalized = (action || '').toString().trim().toLowerCase();
  const allowed = ['login_webview', 'reload_webview', 'logout_webview', 'clear_session', 'edit_judge_setup', 'reset_setup', 'force_judge_assignment'];
  if (!allowed.includes(normalized)) throw new Error('Invalid action');
  db.prepare(`
    UPDATE tablets SET
      pending_action = ?,
      pending_action_payload = ?,
      pending_action_created_at = datetime('now'),
      updated_at = datetime('now')
    WHERE id = ?
  `).run(normalized, payload == null ? null : (typeof payload === 'string' ? payload : JSON.stringify(payload)), tabletId);
  return findById(tabletId);
}

function clearPendingAction(deviceId) {
  db.prepare(`
    UPDATE tablets SET
      pending_action = NULL,
      pending_action_payload = NULL,
      pending_action_created_at = NULL,
      updated_at = datetime('now')
    WHERE device_id = ?
  `).run(deviceId);
}

function updateTablet(id, data) {
  const tablet = findById(id);
  if (!tablet) throw new Error('Tablet not found');

  const updates = [];
  const params = [];

  if (data.judge_name !== undefined) {
    updates.push('judge_name = ?');
    params.push(sanitizeString(data.judge_name, 200));
  }
  if (data.judge_letter !== undefined) {
    const newLetter = sanitizeString(data.judge_letter, 10).toUpperCase();
    if (newLetter) clearOldJudgeAssignmentForOtherTablets(newLetter, tablet.device_id);
    updates.push('judge_letter = ?');
    params.push(newLetter);
  }
  if (data.tablet_label !== undefined) {
    updates.push('tablet_label = ?');
    params.push(sanitizeString(data.tablet_label, 200));
  }
  // judge_color is deprecated for display and ignored.
  if (data.custom_webview_url !== undefined) {
    const url = sanitizeUrl(String(data.custom_webview_url));
    if (url !== '' && !isValidHttpUrl(url)) throw new Error('Invalid custom_webview_url');
    updates.push('custom_webview_url = ?');
    params.push(url || null);
  }
  if (data.note !== undefined) {
    updates.push('note = ?');
    params.push(sanitizeString(data.note, 1000));
  }

  if (updates.length === 0) return findById(id);
  params.push(id);
  db.prepare(`UPDATE tablets SET ${updates.join(', ')}, updated_at = datetime('now') WHERE id = ?`).run(...params);
  return findById(id);
}

function setForceReload(id) {
  const tablet = findById(id);
  if (!tablet) throw new Error('Tablet not found');
  db.prepare("UPDATE tablets SET force_reload = 1, updated_at = datetime('now') WHERE id = ?").run(id);
  return findById(id);
}

/**
 * Force-assign a judge to a tablet (admin override). Updates tablet row and returns payload for force_judge_assignment command.
 */
function forceAssignJudge(tabletId, judgeLetter) {
  const tablet = findById(tabletId);
  if (!tablet) throw new Error('Tablet not found');
  const letter = sanitizeString(String(judgeLetter || '').trim().toUpperCase(), 10);
  if (!letter) throw new Error('Judge letter is required');
  const judgesService = require('./judgesService');
  const judge = judgesService.getByLetter(letter);
  if (!judge) throw new Error(`Judge letter "${letter}" not found. Create the judge in Admin → Judges first.`);
  const judgeName = (judge.judge_name || '').trim();
  clearOldJudgeAssignmentForOtherTablets(letter, tablet.device_id);
  db.prepare(`
    UPDATE tablets SET judge_name = ?, judge_letter = ?, judge_color = NULL, updated_at = datetime('now')
    WHERE id = ?
  `).run(judgeName, letter, tabletId);
  const tabletColor = ensureTabletColorPersisted(tablet.device_id);
  console.log(`[NEW_JUDGE_ASSIGNED]=${JSON.stringify({ tabletId, deviceId: tablet.device_id, judgeLetter: letter, judgeName, tabletColor: tabletColor || '' })}`);
  return {
    judgeLetter: letter,
    judgeName,
    judgeColor: '',
  };
}

/** When a judge's letter is renamed (e.g. J → K), update all tablets assigned to the old letter. */
function updateTabletsByJudgeLetter(oldLetter, newLetter, judgeName) {
  if (!oldLetter || !newLetter) return;
  const oldNorm = sanitizeString(String(oldLetter).trim().toUpperCase(), 10);
  const newNorm = sanitizeString(String(newLetter).trim().toUpperCase(), 10);
  if (oldNorm === newNorm) return;
  const name = judgeName != null ? sanitizeString(String(judgeName), 200) : null;
  if (name !== null) {
    db.prepare("UPDATE tablets SET judge_letter = ?, judge_name = ?, updated_at = datetime('now') WHERE judge_letter = ?").run(newNorm, name, oldNorm);
  } else {
    db.prepare("UPDATE tablets SET judge_letter = ?, updated_at = datetime('now') WHERE judge_letter = ?").run(newNorm, oldNorm);
  }
}

function clearWebviewOverride(id) {
  const tablet = findById(id);
  if (!tablet) throw new Error('Tablet not found');
  db.prepare("UPDATE tablets SET custom_webview_url = NULL, updated_at = datetime('now') WHERE id = ?").run(id);
  return findById(id);
}

function deleteTablet(id) {
  const tablet = findById(id);
  if (!tablet) throw new Error('Tablet not found');
  db.prepare('DELETE FROM tablets WHERE id = ?').run(id);
}

function getDashboardStats() {
  updateOnlineStatus();
  const rows = db.prepare('SELECT battery_level, last_seen_at, wifi_ssid FROM tablets').all();
  const expectedSsid = (require('./settingsService').get().expected_wifi_ssid || '').trim();
  const cutoff = Date.now() - ONLINE_THRESHOLD_MS;
  let online = 0, offline = 0, lowBattery = 0, wrongNetwork = 0;
  rows.forEach((r) => {
    const isOnline = r.last_seen_at && new Date(r.last_seen_at).getTime() > cutoff;
    if (isOnline) online++; else offline++;
    if (r.battery_level != null && r.battery_level < 20) lowBattery++;
    if (expectedSsid && r.wifi_ssid && String(r.wifi_ssid).trim() !== '' && r.wifi_ssid !== expectedSsid) wrongNetwork++;
  });
  return { total: rows.length, online, offline, lowBattery, wrongNetwork };
}

module.exports = {
  list,
  findByDeviceId,
  findById,
  register,
  heartbeat,
  getConfig,
  updateTablet,
  setForceReload,
  setPendingAction,
  clearPendingAction,
  clearWebviewOverride,
  deleteTablet,
  forceAssignJudge,
  updateTabletsByJudgeLetter,
  getDashboardStats,
  updateOnlineStatus,
};
