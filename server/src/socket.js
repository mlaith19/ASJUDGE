/**
 * WebSocket server: all live tablet/admin communication. No polling.
 * ONLINE = socket connected AND heartbeat received within configured timeout.
 * OFFLINE = socket disconnected OR heartbeat not received within timeout.
 */
const { Server } = require('socket.io');
const tabletService = require('./services/tabletService');
const judgesService = require('./services/judgesService');
const settingsService = require('./services/settingsService');
const telegramService = require('./services/telegramService');
const config = require('./config');
const { getHex } = require('./constants/judgeColors');

let io = null;
/** deviceId -> socket (live connection) */
const tabletSockets = new Map();
/** deviceId -> last heartbeat timestamp (ms). Used for true ONLINE only. */
const lastHeartbeatByDeviceId = new Map();
/** deviceId -> last reported loginStatus (LOGGED_IN / LOGGED_OUT / UNKNOWN). */
const lastLoginStatusByDeviceId = new Map();
/** deviceId -> last measured latency (ms), reported by tablet in heartbeat. */
const lastLatencyMsByDeviceId = new Map();
/** deviceId -> last app active state (boolean), reported by tablet in heartbeat. */
const lastAppActiveByDeviceId = new Map();
/** deviceId: tablet is on the setup/assign screen (registered with empty judgeLetter or heartbeat says setup_screen). */
const tabletInSetupByDeviceId = new Set();
/** deviceId: tablet registered as Admin View (__ADMIN__). Receives admin_alert commands. */
const adminTabletDeviceIds = new Set();
/** deviceId: we already sent a low-battery alert so we don't spam on every heartbeat. Reset when battery recovers. */
const lowBatteryAlertedByDeviceId = new Set();
const adminSockets = new Set();
/** Throttle only heartbeat-driven pushes to avoid flooding when many tablets send heartbeats. */
const HEARTBEAT_PUSH_THROTTLE_MS = 800;
let lastHeartbeatPushAt = 0;

function ts() {
  return new Date().toISOString();
}

function log(msg, meta = '') {
  console.log(`[${ts()}] [WS] ${msg} ${meta}`);
}

let _cachedThresholdSec = null;
let _cachedThresholdAt = 0;
const _THRESHOLD_TTL_MS = 5000;

/** Online timeout from Admin Settings. Cached for 5 s to avoid N DB reads per heartbeat push. */
function getOnlineThresholdSeconds() {
  const now = Date.now();
  if (_cachedThresholdSec !== null && now - _cachedThresholdAt < _THRESHOLD_TTL_MS) {
    return _cachedThresholdSec;
  }
  let value = config.onlineThresholdSeconds || 60;
  try {
    const s = settingsService.get();
    if (s && typeof s.judge_release_timeout_seconds === 'number' && s.judge_release_timeout_seconds > 0) {
      value = Math.max(15, Math.min(300, s.judge_release_timeout_seconds));
    } else if (s && typeof s.polling_interval_seconds === 'number' && s.polling_interval_seconds > 0) {
      value = Math.max(15, Math.min(120, s.polling_interval_seconds));
    }
  } catch (_) {}
  _cachedThresholdSec = value;
  _cachedThresholdAt = now;
  return value;
}

/** True ONLINE only: socket exists, connected, and heartbeat received within timeout. */
function isTabletLiveOnline(deviceId) {
  const socket = tabletSockets.get(deviceId);
  if (!socket || !socket.connected) return false;
  const last = lastHeartbeatByDeviceId.get(deviceId);
  if (last == null) return false;
  const timeoutMs = getOnlineThresholdSeconds() * 1000;
  return Date.now() - last < timeoutMs;
}

/**
 * Normalize URL for comparison: trim, lowercase host, ignore trailing slash, add protocol if missing.
 */
function normalizeUrlForLogin(url) {
  const s = (url && typeof url === 'string') ? url.trim() : '';
  if (!s) return null;
  let toParse = s;
  if (!/^https?:\/\//i.test(toParse)) toParse = 'https://' + toParse.replace(/^\/+/, '');
  try {
    const u = new URL(toParse);
    const origin = u.origin.toLowerCase();
    const path = (u.pathname || '/').replace(/\/+$/, '') || '';
    return { origin, path: path.toLowerCase(), pathWithSlash: ('/' + path).replace(/\/+/, '/') };
  } catch (_) {
    return null;
  }
}

/** True if path is root, login, or public auth (not judge area). */
function isLoginOrPublicPath(pathNorm) {
  if (!pathNorm) return true;
  const p = pathNorm.pathWithSlash;
  return p === '/' || p === '' || p === '/login' || p.startsWith('/login/') || p.includes('/login') ||
    p.startsWith('/auth') || p.includes('/auth/') || p.startsWith('/signin') || p.includes('/signin');
}

/** True if path is inside authenticated judge area (e.g. /judge, /judge/home, /he/judge/home). */
function isJudgeAuthenticatedPath(pathNorm) {
  if (!pathNorm) return false;
  const p = pathNorm.pathWithSlash;
  return p === '/judge' || p.startsWith('/judge/') || p.includes('/judge/') || p.endsWith('/judge');
}

/**
 * Compute LOGGED_IN / LOGGED_OUT from Current URL vs Target URL (Control table data only).
 * LOGGED_IN only when: same site as target AND current path is inside authenticated judge area.
 * Same domain alone is NOT enough.
 */
function computeLoginStatusFromUrls(currentWebviewUrl, targetUrl) {
  const tarNorm = normalizeUrlForLogin(targetUrl);
  if (!tarNorm) return 'LOGGED_OUT';
  const curNorm = normalizeUrlForLogin(currentWebviewUrl);
  if (!curNorm) return 'LOGGED_OUT';
  if (curNorm.origin !== tarNorm.origin) return 'LOGGED_OUT';
  if (isLoginOrPublicPath(curNorm)) return 'LOGGED_OUT';
  if (!isJudgeAuthenticatedPath(curNorm)) return 'LOGGED_OUT';
  return 'LOGGED_IN';
}

function buildDashboardState() {
  const judges = judgesService.list();
  const tablets = tabletService.list();
  const tabletByLetter = {};
  const scoreTabletRecency = (t) => {
    const seen = t && t.last_seen_at ? new Date(t.last_seen_at).getTime() : 0;
    const upd = t && t.updated_at ? new Date(t.updated_at).getTime() : 0;
    const idn = Number(t && t.id) || 0;
    return Math.max(seen || 0, upd || 0, idn || 0);
  };
  tablets.forEach((t) => {
    const L = (t.judge_letter || '').toString().toUpperCase().trim();
    if (!L) return;
    const prev = tabletByLetter[L];
    if (!prev || scoreTabletRecency(t) >= scoreTabletRecency(prev)) {
      tabletByLetter[L] = t;
    }
  });
  const settings = settingsService.get();
  const expectedSsid = (settings && settings.expected_wifi_ssid || '').trim();

  /** Tablets that are connected (ONLINE) but not assigned to any judge — show as "Pending Assign" so they appear ONLINE and admin can Assign.
   *  Also includes tablets that have an old assignment but are currently on the setup/assign screen. */
  const unassignedOnlineTablets = tablets.filter((t) => {
    if (!isTabletLiveOnline(t.device_id)) return false;
    const inSetup = tabletInSetupByDeviceId.has(t.device_id) ||
      (t.foreground_state || '').toString().toLowerCase() === 'setup_screen';
    const hasLetter = (t.judge_letter || '').toString().trim();
    // Show in Pending Assign if no judge letter, OR if has a stale letter but is on setup screen.
    return !hasLetter || inSetup;
  });
  const pendingColumns = unassignedOnlineTablets.map((t) => ({
    judge: {
      judge_letter: '—',
      judge_name: 'Pending Assign',
      judge_color: null,
      judge_color_hex: '#6b7280',
      online: true,
    },
    tablet: { ...t, loginStatus: null },
  }));

  const judgeColumns = judges.map((j) => {
    const judgeKey = (j.judge_letter || '').toString().toUpperCase().trim();
    const tablet = judgeKey ? (tabletByLetter[judgeKey] || null) : null;
    const inSetup = tablet ? (tabletInSetupByDeviceId.has(tablet.device_id) ||
      (tablet.foreground_state || '').toString().toLowerCase() === 'setup_screen') : false;
    const online = tablet ? (isTabletLiveOnline(tablet.device_id) && !inSetup) : false;
    let loginStatus = null;
    if (tablet && online) {
      // Prefer status reported by tablet (heartbeat / login_status_changed); fallback to URL-based.
      const reported = lastLoginStatusByDeviceId.get(tablet.device_id);
      if (reported === 'LOGGED_IN' || reported === 'LOGGED_OUT') {
        loginStatus = reported;
      } else {
        const targetUrl = (tablet.custom_webview_url && tablet.custom_webview_url.trim())
          ? tablet.custom_webview_url.trim()
          : (settings && settings.global_webview_url ? settings.global_webview_url.trim() : '');
        loginStatus = computeLoginStatusFromUrls(tablet.current_webview_url, targetUrl);
      }
    }
    /** When OFFLINE, do not expose live session/device data; only id, device_id, last_seen_at, and config (e.g. custom_webview_url) for display. */
    let tabletForColumn = null;
    if (tablet) {
      if (online) {
        tabletForColumn = { ...tablet, loginStatus };
      } else {
        tabletForColumn = {
          id: tablet.id,
          device_id: tablet.device_id,
          last_seen_at: tablet.last_seen_at,
          custom_webview_url: tablet.custom_webview_url,
          judge_letter: tablet.judge_letter,
          judge_name: tablet.judge_name,
          loginStatus: null,
          battery_level: null,
          battery_temperature: null,
          charging: null,
          wifi_ssid: null,
          ip_address: null,
          current_webview_url: null,
        };
      }
    }
    // Color source of truth: tablet.tablet_color only.
    const displayColorHex = tablet ? (getHex(tablet.tablet_color) || '#6b7280') : '#6b7280';
    return {
      judge: {
        ...j,
        judge_color_hex: displayColorHex,
        online,
      },
      tablet: tabletForColumn,
    };
  });

  const columns = pendingColumns.concat(judgeColumns);

  let onlineCount = 0;
  tablets.forEach((t) => {
    if (isTabletLiveOnline(t.device_id)) onlineCount++;
  });
  let lowBattery = 0;
  let wrongNetwork = 0;
  tablets.forEach((t) => {
    if (t.battery_level != null && t.battery_level < 20) lowBattery++;
    if (expectedSsid && t.wifi_ssid && String(t.wifi_ssid).trim() !== '' && t.wifi_ssid !== expectedSsid) wrongNetwork++;
  });

  const stats = {
    total: tablets.length,
    online: onlineCount,
    offline: tablets.length - onlineCount,
    lowBattery,
    wrongNetwork,
  };

  return { stats, columns, settings };
}

/**
 * State for the Tablets list page: all tablets with live online status (no judge columns).
 */
function buildTabletsListState() {
  const tablets = tabletService.list();
  const withLive = tablets.map((t) => ({
    id: t.id,
    device_id: t.device_id,
    isLiveOnline: isTabletLiveOnline(t.device_id),
    latency_ms: lastLatencyMsByDeviceId.get(t.device_id) ?? null,
    app_active: (lastAppActiveByDeviceId.has(t.device_id) ? lastAppActiveByDeviceId.get(t.device_id) : null),
  }));
  let onlineCount = 0;
  withLive.forEach((t) => { if (t.isLiveOnline) onlineCount++; });
  return {
    tablets: withLive,
    stats: {
      total: tablets.length,
      online: onlineCount,
      offline: tablets.length - onlineCount,
      lowBattery: tablets.filter((t) => t.battery_level != null && t.battery_level < 20).length,
    },
  };
}

/**
 * State for Judges page only (single source of truth for assignment/live status).
 * Snapshot-driven to avoid stale/cached merges on frontend.
 */
function buildJudgesState() {
  const judges = judgesService.list();
  const tablets = tabletService.list();
  // Source of truth: current DB value per device_id (no "newest wins" by timestamps).
  const byDeviceId = {};
  tablets.forEach((t) => {
    const dev = (t.device_id || '').toString().trim();
    if (!dev) return;
    byDeviceId[dev] = t;
  });
  const tabletByJudgeLetter = {};
  Object.values(byDeviceId).forEach((t) => {
    const key = (t.judge_letter || '').toString().trim().toUpperCase();
    if (!key) return;
    // Active assignment only: online tablet owns the judge row.
    if (!isTabletLiveOnline(String(t.device_id || ''))) return;
    // Tablet in setup/assign screen is not actively assigned to any judge.
    if (tabletInSetupByDeviceId.has(String(t.device_id || ''))) return;
    if (tabletByJudgeLetter[key] && tabletByJudgeLetter[key].device_id !== t.device_id) {
      console.log(`[JUDGES_ASSIGNMENT_CONFLICT]=${JSON.stringify({ judgeLetter: key, keepDeviceId: tabletByJudgeLetter[key].device_id, dropDeviceId: t.device_id })}`);
      return;
    }
    tabletByJudgeLetter[key] = t;
  });

  const usedDeviceIds = new Set();
  const rows = judges.map((j) => {
    const letter = (j.judge_letter || '').toString().trim().toUpperCase();
    let assignedTablet = letter ? (tabletByJudgeLetter[letter] || null) : null;

    // Guard: never allow same tabletId rendered under 2 judges in one snapshot.
    const devId = assignedTablet && assignedTablet.device_id ? String(assignedTablet.device_id) : '';
    if (devId && usedDeviceIds.has(devId)) assignedTablet = null;
    if (devId) usedDeviceIds.add(devId);

    const assignedTabletId = assignedTablet ? String(assignedTablet.device_id || '') : '';
    const isAssignedTabletOnline = assignedTablet ? isTabletLiveOnline(assignedTabletId) : false;
    // Judges page must show color/tablet only for active live assignment.
    const hasActiveAssignment = !!assignedTablet && isAssignedTabletOnline;
    const currentTabletId = hasActiveAssignment ? assignedTabletId : '';
    const online = hasActiveAssignment;
    const colorHex = hasActiveAssignment ? (getHex(assignedTablet.tablet_color) || '#6b7280') : '#6b7280';
    const loginStatus = hasActiveAssignment
      ? (lastLoginStatusByDeviceId.get(assignedTabletId) || null)
      : null;

    return {
      id: j.id,
      judge_letter: letter,
      judge_name: j.judge_name || '',
      judge_color: '',
      judge_color_hex: colorHex,
      current_tablet_id: currentTabletId,
      tablet_db_id: hasActiveAssignment ? (assignedTablet.id || null) : null,
      online,
      loginStatus,
      assignment_status: hasActiveAssignment ? 'assigned' : 'unassigned',
    };
  });

  const total = rows.length;
  const onlineCount = rows.filter((r) => r.online).length;
  const deviceToJudge = {};
  rows.forEach((r) => {
    if (r.current_tablet_id) deviceToJudge[r.current_tablet_id] = r.judge_letter;
  });
  console.log(`[JUDGES_STATE_DEVICE_TO_JUDGE]=${JSON.stringify(deviceToJudge)}`);

  // Tablets that are online but not assigned to any judge — available for ASSIGN
  const assignedDevIds = new Set(rows.filter(r => r.current_tablet_id).map(r => r.current_tablet_id));
  const availableTablets = Object.values(byDeviceId)
    .filter(t => {
      const did = String(t.device_id || '');
      return did && isTabletLiveOnline(did) && !assignedDevIds.has(did);
    })
    .map(t => ({
      id: t.id,
      label: (t.tablet_label || '').toString().trim() || String(t.device_id || '').substring(0, 14) + '…',
    }));

  return {
    judges: rows,
    availableTablets,
    stats: {
      total,
      online: onlineCount,
      offline: total - onlineCount,
    },
    snapshot_at: Date.now(),
  };
}

/**
 * Push dashboard state to all connected admin clients. Event-driven only; no timer.
 * @param {string} reason - Event that triggered the push (e.g. 'tablet_register', 'heartbeat', 'command_completed'). Used for logging.
 */
function pushDashboardToAdmin(reason) {
  if (adminSockets.size === 0) return;
  console.log(`[JUDGES_WS_EVENT]=${reason}`);
  const now = Date.now();
  if (reason === 'heartbeat' && now - lastHeartbeatPushAt < HEARTBEAT_PUSH_THROTTLE_MS) return;
  if (reason === 'heartbeat') lastHeartbeatPushAt = now;
  const state = buildDashboardState();
  const tabletsState = buildTabletsListState();
  const judgesState = buildJudgesState();
  adminSockets.forEach((socket) => {
    try {
      socket.emit('dashboard_state', state);
      socket.emit('tablets_state', tabletsState);
      socket.emit('judges_state', judgesState);
    } catch (e) {
      log('pushDashboardToAdmin error', e.message);
    }
  });
  log(`dashboard push [${reason}] to ${adminSockets.size} admin(s)`);
}

function broadcastToAdmin(event, data) {
  if (adminSockets.size === 0) return;
  const payload = typeof data === 'object' && data !== null ? data : { data };
  adminSockets.forEach((socket) => {
    try {
      socket.emit(event, payload);
    } catch (e) {
      log('broadcastToAdmin error', e.message);
    }
  });
  log(`broadcast to ${adminSockets.size} admin(s): ${event}`);
}

/**
 * Send admin_alert command to all tablets registered as Admin View (__ADMIN__),
 * but only when admin_tablet_alerts_enabled setting is on (default: on).
 * @param {string} eventType - e.g. 'judge_online', 'judge_offline', 'judge_assigned'
 * @param {object} data - extra fields merged into the payload
 */
function notifyAdminTablets(eventType, data = {}) {
  // Telegram is always sent regardless of tablet state
  try { telegramService.notify(eventType, data); } catch (_) {}

  if (adminTabletDeviceIds.size === 0) return;
  try {
    const s = settingsService.get();
    // admin_tablet_alerts_enabled: null or 1 = enabled, 0 = disabled
    if (s && s.admin_tablet_alerts_enabled === 0) return;
  } catch (_) {}
  const payload = { eventType, ...data };
  adminTabletDeviceIds.forEach((deviceId) => {
    sendCommandToTablet(deviceId, 'admin_alert', payload);
  });
  log(`admin_alert [${eventType}] sent to ${adminTabletDeviceIds.size} admin tablet(s)`);
}

function sendCommandToTablet(deviceId, action, payload = null) {
  const socket = tabletSockets.get(deviceId);
  if (!socket || !socket.connected) {
    log('command not sent: no socket for device', deviceId);
    return false;
  }
  try {
    const act = (action || '').toString().trim().toLowerCase();
    socket.emit('tablet_command', {
      type: 'tablet_command',
      action: act,
      deviceId,
      payload: payload || {},
      timestamp: Date.now(),
    });
    if (act === 'login_webview') log('login_webview sent to tablet', deviceId);
    else if (act === 'logout_webview') log('logout_webview sent to tablet', deviceId);
    else if (act === 'force_judge_assignment') {
      log('force_judge_assignment (judge assignment) sent to tablet', deviceId);
      // Notify admin tablets about the assignment change (only for non-admin target tablets).
      if (!adminTabletDeviceIds.has(deviceId)) {
        const newLetter = (payload && payload.judgeLetter) ? String(payload.judgeLetter) : '';
        const newName = (payload && payload.judgeName) ? String(payload.judgeName) : '';
        notifyAdminTablets('judge_assigned', { judgeLetter: newLetter, judgeName: newName });
      }
    } else if (act === 'edit_judge_setup' || act === 'reset_setup') {
      log('edit_judge_setup/reset_setup sent to tablet', deviceId);
      // Notify admin tablets — this action means the judge is being unassigned from this tablet.
      if (!adminTabletDeviceIds.has(deviceId)) {
        const t = tabletService.findByDeviceId(deviceId);
        const jl = t ? (t.judge_letter || '').trim() : '';
        if (jl && jl !== '__ADMIN__') {
          notifyAdminTablets('judge_unassigned', { judgeLetter: jl, judgeName: t ? (t.judge_name || '') : '' });
        }
      }
    } else log('command sent to tablet', `${deviceId} action=${act}`);
    pushDashboardToAdmin('command_sent');
    return true;
  } catch (e) {
    log('sendCommandToTablet error', e.message);
    return false;
  }
}

function onTabletDisconnected(deviceId) {
  const wasAdmin = adminTabletDeviceIds.has(deviceId);
  tabletSockets.delete(deviceId);
  lastHeartbeatByDeviceId.delete(deviceId);
  tabletInSetupByDeviceId.delete(deviceId);
  adminTabletDeviceIds.delete(deviceId);
  lowBatteryAlertedByDeviceId.delete(deviceId);
  const conn = require('./db/connection');
  const dbTablets = conn.dbTablets || conn;
  const before = dbTablets.prepare('SELECT is_online FROM tablets WHERE device_id = ?').get(deviceId);
  if (before && before.is_online) {
    dbTablets.prepare("UPDATE tablets SET is_online = 0, updated_at = datetime('now') WHERE device_id = ?").run(deviceId);
  }
  // Notify admin tablets when a judge (non-admin) tablet goes offline.
  if (!wasAdmin) {
    const tablet = tabletService.findByDeviceId(deviceId);
    const judgeLetter = tablet ? (tablet.judge_letter || '').trim() : '';
    if (judgeLetter && judgeLetter !== '__ADMIN__') {
      notifyAdminTablets('judge_offline', { judgeLetter, judgeName: tablet ? (tablet.judge_name || '') : '' });
    }
  }
  broadcastToAdmin('tablet_offline', { deviceId, tablet: tabletService.findByDeviceId(deviceId) });
  pushDashboardToAdmin('tablet_disconnect');
}

function init(httpServer, sessionMiddleware) {
  if (io) return io;
  const allowedOrigins = process.env.ALLOWED_ORIGINS
    ? process.env.ALLOWED_ORIGINS.split(',').map((s) => s.trim())
    : ['http://localhost:3000', 'http://localhost:5000'];

  io = new Server(httpServer, {
    path: '/socket.io',
    cors: { origin: allowedOrigins, methods: ['GET', 'POST'] },
    pingTimeout: 10000,
    pingInterval: 5000,
  });


  io.of('/tablet').on('connection', (socket) => {
    log('tablet socket connected', socket.id);
    let deviceId = null;

    socket.on('tablet_register', (msg) => {
      const payload = msg && typeof msg === 'object' ? msg : {};
      const devId = (payload.deviceId || payload.device_id || '').toString().trim();
      if (!devId) {
        log('tablet_register: missing deviceId');
        return;
      }
      log('tablet_register received', `deviceId=${devId}`);
      deviceId = devId;
      const judgeLetter = (payload.judgeLetter || payload.judge_letter || '').toString().trim().toUpperCase();
      const tabletLabel = (payload.tabletLabel || payload.tablet_label || '').toString().trim();
      const appVersion = (payload.appVersion || payload.app_version || '').toString().trim();
      try {
        tabletService.register({
          deviceId: devId,
          judgeLetter: judgeLetter || undefined,
          tabletLabel: tabletLabel || undefined,
        });
      } catch (e) {
        log('tablet_register error', e.message);
        socket.emit('register_error', { error: e.message });
        return;
      }
      const existing = tabletSockets.get(devId);
      if (existing && existing !== socket) {
        try { existing.disconnect(true); } catch (_) {}
      }
      tabletSockets.set(devId, socket);
      socket.deviceId = devId;
      lastHeartbeatByDeviceId.set(devId, Date.now());
      // Track whether tablet is on the setup/assign screen (registered with no judge letter).
      if (!judgeLetter) {
        tabletInSetupByDeviceId.add(devId);
      } else {
        tabletInSetupByDeviceId.delete(devId);
      }
      // Track admin tablets and notify on judge connect.
      if (judgeLetter === '__ADMIN__') {
        adminTabletDeviceIds.add(devId);
      } else {
        adminTabletDeviceIds.delete(devId);
        if (judgeLetter) {
          const judgeName = (payload.judgeName || payload.judge_name || '').toString().trim();
          notifyAdminTablets('judge_online', { judgeLetter, judgeName });
        }
      }
      const tablet = tabletService.findByDeviceId(devId);
      const cfg = tabletService.getConfig(devId) || {};
      const colorKey = (cfg.tablet_color || cfg.tabletColor || cfg.tabletDisplayColor || '').toString().trim().toLowerCase();
      const cfgWithColor = {
        ...cfg,
        tablet_color: colorKey,
        tabletColor: colorKey,
        tabletDisplayColor: colorKey,
      };
      console.log(`[SERVER_SENT_TABLET_COLOR]=${colorKey}`);
      console.log(`[SERVER_SENT_DEVICE_ID]=${devId}`);
      console.log(`[SERVER_SENT_PAYLOAD]=${JSON.stringify({ config: cfgWithColor || null, tablet: tablet ? { id: tablet.id, device_id: tablet.device_id } : null })}`);
      socket.emit('register_ok', {
        config: cfgWithColor,
        tablet: tablet ? { id: tablet.id, device_id: tablet.device_id } : null,
      });
      const pending = (tablet && tablet.pending_action) ? tablet.pending_action.trim() : '';
      if (pending) {
        log('judge assignment / command sent on register', `device=${devId} action=${pending}`);
        sendCommandToTablet(devId, pending, tablet.pending_action_payload || null);
      }
      broadcastToAdmin('tablet_connected', { deviceId: devId, tablet: tabletService.findByDeviceId(devId) });
      pushDashboardToAdmin('tablet_register');
      log('tablet marked live ONLINE', devId);
    });

    socket.on('heartbeat', (msg) => {
      const telemDbg = process.env.TELEM_DEBUG === '1';
      if (telemDbg) {
        try {
          console.log('[TELEM_C_in_raw]', JSON.stringify(msg));
        } catch (e) {
          console.log('[TELEM_C_in_raw]', String(msg), e.message);
        }
      }
      let raw = msg && typeof msg === 'object' ? msg : {};
      if (Array.isArray(raw) && raw.length > 0) raw = raw[0] || {};
      const payload = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
      const devId = (payload.deviceId || payload.device_id || deviceId || '').toString().trim();
      if (telemDbg) {
        console.log('[TELEM_C_after_unwrap]', JSON.stringify({
          deviceId: devId,
          batteryLevel: payload.batteryLevel ?? payload.battery_level,
          charging: payload.charging,
          batteryTemperature: payload.batteryTemperature ?? payload.battery_temperature,
          cpuUsage: payload.cpuUsage ?? payload.cpu_usage,
          wifiSSID: payload.wifiSSID ?? payload.wifi_ssid,
          ipAddress: payload.ipAddress ?? payload.ip_address,
          currentWebviewUrl: (payload.currentWebviewUrl || payload.current_webview_url || '').toString().slice(0, 200),
          keys: Object.keys(payload),
        }));
      }
      if (!devId) return;
      deviceId = devId;
      lastHeartbeatByDeviceId.set(devId, Date.now());

      // ACK/PONG for latency measurement (echo sent_at back to tablet).
      try {
        const sentAt = payload.sent_at ?? payload.sentAt ?? null;
        if (sentAt != null) socket.emit('heartbeat_ack', { sent_at: sentAt });
      } catch (_) {}

      // Keep last-known live-only fields in memory (do not touch DB).
      try {
        const lat = payload.latency_ms ?? payload.latencyMs;
        const latNum = lat != null ? parseInt(String(lat), 10) : NaN;
        if (!Number.isNaN(latNum)) lastLatencyMsByDeviceId.set(devId, latNum);
      } catch (_) {}
      try {
        const aa = payload.app_active ?? payload.appActive;
        if (aa === true || aa === false) lastAppActiveByDeviceId.set(devId, aa);
        else if (aa != null) {
          const s = String(aa).trim().toLowerCase();
          if (s === 'true' || s === 'false') lastAppActiveByDeviceId.set(devId, s === 'true');
        }
      } catch (_) {}
      // Sync setup-screen flag from heartbeat foregroundState (handles server restart).
      try {
        const fs = (payload.foregroundState ?? payload.foreground_state ?? '').toString().toLowerCase();
        if (fs === 'setup_screen') tabletInSetupByDeviceId.add(devId);
        else if (fs && tabletInSetupByDeviceId.has(devId)) tabletInSetupByDeviceId.delete(devId);
      } catch (_) {}

      const loginStatus = String(payload.loginStatus ?? payload.login_status ?? 'UNKNOWN').toUpperCase();
      if (loginStatus === 'LOGGED_IN' || loginStatus === 'LOGGED_OUT') {
        lastLoginStatusByDeviceId.set(devId, loginStatus);
      }
      try {
        tabletService.heartbeat(devId, {
          judgeLetter: payload.judgeLetter ?? payload.judge_letter,
          judgeName: payload.judgeName ?? payload.judge_name,
          judgeColor: payload.judgeColor ?? payload.judge_color,
          tabletLabel: payload.tabletLabel ?? payload.tablet_label,
          batteryLevel: payload.batteryLevel ?? payload.battery_level,
          batteryTemperature: payload.batteryTemperature ?? payload.battery_temperature,
          cpuUsage: payload.cpuUsage ?? payload.cpu_usage,
          charging: payload.charging,
          ipAddress: payload.ipAddress ?? payload.ip_address,
          appVersion: payload.appVersion ?? payload.app_version,
          currentWebviewUrl: payload.currentWebviewUrl ?? payload.current_webview_url,
          wifiSSID: payload.wifiSSID ?? payload.wifi_ssid,
          wifiBSSID: payload.wifiBSSID ?? payload.wifi_bssid,
          gateway: payload.gateway,
          signalStrength: payload.signalStrength ?? payload.signal_strength,
          wifiFrequency: payload.wifiFrequency ?? payload.wifi_frequency,
          foregroundState: payload.foregroundState ?? payload.foreground_state,
          kioskModeActive: payload.kioskModeActive ?? payload.kiosk_mode_active,
          screenOn: payload.screenOn ?? payload.screen_on,
          connectivityState: payload.connectivityState ?? payload.connectivity_state,
        });
      } catch (e) {
        log('heartbeat error', e.message);
        return;
      }
      const tabletRow = tabletService.findByDeviceId(devId);
      if (telemDbg && tabletRow) {
        console.log('[TELEM_D_db_row]', JSON.stringify({
          device_id: tabletRow.device_id,
          battery_level: tabletRow.battery_level,
          charging: tabletRow.charging,
          battery_temperature: tabletRow.battery_temperature,
          cpu_usage: tabletRow.cpu_usage,
          wifi_ssid: tabletRow.wifi_ssid,
          ip_address: tabletRow.ip_address,
          current_webview_url: (tabletRow.current_webview_url || '').toString().slice(0, 200),
          last_seen_at: tabletRow.last_seen_at,
        }));
      }
      const tabletWithLive = tabletRow ? {
        ...tabletRow,
        isLiveOnline: true,
        latency_ms: lastLatencyMsByDeviceId.get(devId) ?? null,
        app_active: (lastAppActiveByDeviceId.has(devId) ? lastAppActiveByDeviceId.get(devId) : null),
      } : null;
      const adminBroadcast = {
        deviceId: devId,
        tablet: tabletWithLive,
        isInSetupMode: tabletInSetupByDeviceId.has(devId),
        payload: {
          batteryLevel: payload.batteryLevel ?? payload.battery_level,
          currentWebviewUrl: payload.currentWebviewUrl ?? payload.current_webview_url,
          loginStatus: payload.loginStatus ?? payload.login_status,
        },
      };
      if (telemDbg) {
        const t = tabletWithLive;
        console.log('[TELEM_E_broadcast]', JSON.stringify({
          deviceId: devId,
          tablet_telemetry: t ? {
            battery_level: t.battery_level,
            charging: t.charging,
            battery_temperature: t.battery_temperature,
            cpu_usage: t.cpu_usage,
            wifi_ssid: t.wifi_ssid,
            ip_address: t.ip_address,
            current_webview_url: (t.current_webview_url || '').toString().slice(0, 200),
          } : null,
          admins: adminSockets.size,
        }));
      }
      broadcastToAdmin('tablet_heartbeat', adminBroadcast);
      pushDashboardToAdmin('heartbeat');

      // Low-battery alert: notify admin tablets once when battery first drops below 20%.
      // Reset the alert flag when battery recovers above 25% (hysteresis to avoid flapping).
      if (!adminTabletDeviceIds.has(devId)) {
        const batt = payload.batteryLevel ?? payload.battery_level;
        const battNum = batt != null ? parseInt(String(batt), 10) : NaN;
        const charging = payload.charging === true || payload.charging === 1 || payload.charging === '1';
        if (!Number.isNaN(battNum)) {
          if (battNum > 0 && battNum < 20 && !charging && !lowBatteryAlertedByDeviceId.has(devId)) {
            lowBatteryAlertedByDeviceId.add(devId);
            const t = tabletService.findByDeviceId(devId);
            const judgeLetter = t ? (t.judge_letter || '').trim() : '';
            const judgeName = t ? (t.judge_name || '').trim() : '';
            notifyAdminTablets('low_battery', { judgeLetter, judgeName, batteryLevel: battNum });
          } else if ((battNum >= 25 || charging) && lowBatteryAlertedByDeviceId.has(devId)) {
            lowBatteryAlertedByDeviceId.delete(devId);
          }
        }
      }
    });

    socket.on('command_completed', (msg) => {
      const payload = msg && typeof msg === 'object' ? msg : {};
      const devId = (payload.deviceId || payload.device_id || deviceId || '').toString().trim();
      const action = (payload.action || '').toString().trim().toLowerCase();
      const success = payload.success !== false;
      if (devId) {
        tabletService.clearPendingAction(devId);
        log('command_completed received', `device=${devId} action=${action} success=${success}`);
        broadcastToAdmin('command_completed', {
          deviceId: devId,
          action,
          success,
          timestamp: payload.timestamp || Date.now(),
        });
        pushDashboardToAdmin('command_completed');
      }
    });

    socket.on('login_status_changed', (msg) => {
      const payload = msg && typeof msg === 'object' ? msg : {};
      const devId = (payload.deviceId || payload.device_id || deviceId || '').toString().trim();
      const status = String(payload.loginStatus ?? payload.login_status ?? 'UNKNOWN').toUpperCase();
      if (devId && (status === 'LOGGED_IN' || status === 'LOGGED_OUT')) {
        lastLoginStatusByDeviceId.set(devId, status);
        log('loginStatus changed', `device=${devId} status=${status}`);
        // Notify admin tablets on judge login / logout (skip admin tablets themselves).
        if (!adminTabletDeviceIds.has(devId)) {
          const tablet = tabletService.findByDeviceId(devId);
          const judgeLetter = tablet ? (tablet.judge_letter || '').trim() : '';
          const judgeName = tablet ? (tablet.judge_name || '').trim() : '';
          if (judgeLetter && judgeLetter !== '__ADMIN__') {
            notifyAdminTablets(status === 'LOGGED_IN' ? 'judge_login' : 'judge_logout', { judgeLetter, judgeName });
          }
        }
        pushDashboardToAdmin('login_status_changed');
      }
    });

    socket.on('disconnect', (reason) => {
      log('tablet socket disconnected', `${socket.id} reason=${reason || ''}`);
      if (deviceId) {
        log('tablet marked OFFLINE (disconnect)', deviceId);
        onTabletDisconnected(deviceId);
      }
    });
  });

  // No session check on the socket: CORS (allowedOrigins) is the access gate.
  // All write operations remain protected by session auth on HTTP routes.

  io.of('/admin').on('connection', (socket) => {
    log(`admin socket connected ${socket.id}`);
    adminSockets.add(socket);
    try {
      pushDashboardToAdmin('admin_connect');
    } catch (e) {
      log('admin initial state error', e.message);
    }
    socket.on('request_state', () => {
      try {
        const state = buildDashboardState();
        socket.emit('dashboard_state', state);
        socket.emit('tablets_state', buildTabletsListState());
        socket.emit('judges_state', buildJudgesState());
        log('dashboard push [request_state] to 1 admin(s)');
      } catch (e) {
        log('request_state error', e.message);
      }
    });
    socket.on('disconnect', (reason) => {
      log(`admin socket disconnected ${socket.id} reason=${reason || ''}`);
      adminSockets.delete(socket);
    });
  });

  log('WebSocket server attached; tablet and admin namespaces ready; dashboard is event-driven only (no interval); ONLINE = socket + fresh heartbeat only');
  return io;
}

function getTabletSocket(deviceId) {
  return tabletSockets.get(deviceId) || null;
}

function isTabletConnected(deviceId) {
  const s = tabletSockets.get(deviceId);
  return !!(s && s.connected);
}

function getTabletLiveData(deviceId) {
  return {
    latency_ms: lastLatencyMsByDeviceId.get(deviceId) ?? null,
    app_active: lastAppActiveByDeviceId.has(deviceId) ? lastAppActiveByDeviceId.get(deviceId) : null,
  };
}

module.exports = {
  init,
  get io() { return io; },
  getTabletSocket,
  isTabletConnected,
  isTabletLiveOnline,
  sendCommandToTablet,
  broadcastToAdmin,
  buildDashboardState,
  buildTabletsListState,
  buildJudgesState,
  getTabletLiveData,
  /** Call when judge or tablet data changes so admin clients get a fresh dashboard (event-driven). */
  pushDashboardToAdmin,
  getLoginStatus: function (deviceId) {
    return lastLoginStatusByDeviceId.get(deviceId) || null;
  },
  isTabletInSetupMode: function (deviceId) {
    return tabletInSetupByDeviceId.has(String(deviceId || ''));
  },
};
