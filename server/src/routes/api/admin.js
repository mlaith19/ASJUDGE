/**
 * JSON API for admin (V0 Next.js app). All routes require session auth.
 */
const express = require('express');
const router = express.Router();
const rateLimit = require('express-rate-limit');

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many login attempts, please try again later' },
});
const { requireAuth } = require('../../middleware/auth');
const judgesService = require('../../services/judgesService');
const tabletService = require('../../services/tabletService');
const settingsService = require('../../services/settingsService');
const adminService = require('../../services/adminService');
const { getHex } = require('../../constants/judgeColors');
const socketService = require('../../socket');

function mapJudgeToV0(j, liveOnline = false) {
  const tablet = j.device_id ? { device_id: j.device_id } : null;
  const online = liveOnline || (!!tablet && (socketService.isTabletLiveOnline && socketService.isTabletLiveOnline(j.device_id)));
  // Use tablet_color if the judge has an active online tablet, else gray
  const tabletRow = j.device_id ? require('../../services/tabletService').findByDeviceId(j.device_id) : null;
  const color = (online && tabletRow && tabletRow.tablet_color)
    ? (getHex(tabletRow.tablet_color) || '#6b7280')
    : '#6b7280';
  return {
    id: String(j.id),
    letter: (j.judge_letter || '').toUpperCase(),
    name: j.judge_name || '',
    color,
    username: j.username || '',
    password: '',
    status: online ? 'ONLINE' : 'OFFLINE',
    tabletId: tablet ? tablet.device_id : null,
    judgeType: j.judge_type || 'JUDGE',
  };
}

router.get('/me', requireAuth, (req, res) => {
  res.json({ username: req.session.adminUsername || 'admin' });
});

router.post('/login', loginLimiter, async (req, res) => {
  const { username, password } = req.body || {};
  if (!username || !password) {
    return res.status(400).json({ error: 'Username and password required' });
  }
  try {
    const admin = await adminService.verifyPassword(String(username).trim(), password);
    if (!admin) {
      return res.status(401).json({ error: 'Invalid username or password' });
    }
    req.session.adminId = admin.id;
    req.session.adminUsername = admin.username;
    return res.json({ ok: true, username: admin.username });
  } catch (err) {
    return res.status(500).json({ error: 'Login failed' });
  }
});

router.post('/logout', (req, res) => {
  req.session.destroy(() => {
    res.json({ ok: true });
  });
});

router.get('/judges', requireAuth, (req, res) => {
  try {
    const list = judgesService.listWithTabletStatus();
    const v0 = list.map((j) => mapJudgeToV0(j, !!(j.device_id && (socketService.isTabletLiveOnline && socketService.isTabletLiveOnline(j.device_id)))));
    res.json(v0);
  } catch (err) {
    res.status(500).json({ error: err.message || 'Failed' });
  }
});

router.get('/judges/:id/password', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const judge = judgesService.getById(id);
  if (!judge) return res.status(404).json({ error: 'Not found' });
  res.json({ password: judge.password || '' });
});

router.post('/judges', requireAuth, (req, res) => {
  try {
    const body = req.body || {};
    const letter = (body.letter || '').toString().trim().toUpperCase();
    const judge = judgesService.create({
      judge_name: body.name,
      judge_letter: letter || undefined,
      judge_color: body.color,
      username: body.username,
      password: body.password || '',
      judge_type: body.judgeType || 'JUDGE',
    });
    res.status(201).json(mapJudgeToV0({ ...judge, online: false, device_id: null }, false));
  } catch (err) {
    res.status(400).json({ error: err.message || 'Failed' });
  }
});

router.get('/judges/:id', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const judge = judgesService.getById(id);
  if (!judge) return res.status(404).json({ error: 'Not found' });
  const list = judgesService.listWithTabletStatus();
  const withStatus = list.find((j) => j.id === judge.id);
  const devId = withStatus && withStatus.device_id;
  const online = !!(devId && socketService.isTabletLiveOnline && socketService.isTabletLiveOnline(devId));
  res.json(mapJudgeToV0({ ...judge, online, device_id: devId }));
});

router.patch('/judges/:id', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const body = req.body || {};
  try {
    const payload = {};
    if (body.name !== undefined) payload.judge_name = body.name;
    if (body.color !== undefined) payload.judge_color = body.color;
    if (body.username !== undefined) payload.username = body.username;
    if (body.password !== undefined) payload.password = body.password;
    if (body.judgeType !== undefined) payload.judge_type = body.judgeType;
    const judge = judgesService.update(id, payload);
    const list = judgesService.listWithTabletStatus();
    const withStatus = list.find((j) => j.id === judge.id);
    const devId = withStatus && withStatus.device_id;
    const online = !!(devId && socketService.isTabletLiveOnline && socketService.isTabletLiveOnline(devId));
    res.json(mapJudgeToV0({ ...judge, online, device_id: devId }));
  } catch (err) {
    res.status(400).json({ error: err.message || 'Failed' });
  }
});

router.delete('/judges/:id', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  try {
    judgesService.remove(id);
    res.json({ ok: true });
  } catch (err) {
    res.status(400).json({ error: err.message || 'Failed' });
  }
});

router.post('/tablets/:id/pending-action', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const action = (req.body.action || '').trim().toLowerCase();
  try {
    tabletService.setPendingAction(id, action, req.body.payload || null);
    const tablet = tabletService.findById(id);
    if (tablet && tablet.device_id) {
      socketService.sendCommandToTablet(tablet.device_id, action, req.body.payload || null);
    }
    res.json({ ok: true });
  } catch (err) {
    res.status(400).json({ error: err.message || 'Failed' });
  }
});

router.get('/tablets', requireAuth, (req, res) => {
  try {
    const tablets = tabletService.list({});
    const v0 = tablets.map((t) => {
      const inSetup = !!(socketService.isTabletInSetupMode && socketService.isTabletInSetupMode(t.device_id));
      return {
        id: t.device_id,
        tabletDbId: t.id,
        judgeLetter: inSetup ? '' : (t.judge_letter || '').toUpperCase(),
        judgeName: inSetup ? '' : (t.judge_name || ''),
        judgeColor: getHex(t.tablet_color) || '#6b7280',
        status: (socketService.isTabletLiveOnline && socketService.isTabletLiveOnline(t.device_id)) ? 'ONLINE' : 'OFFLINE',
        battery: t.battery_level != null ? t.battery_level : 0,
        ip: t.ip_address || '',
        lastSeen: t.last_seen_at ? new Date(t.last_seen_at).toLocaleString() : '',
        wifiName: t.wifi_ssid || null,
        isInSetupMode: inSetup,
      };
    });
    res.json(v0);
  } catch (err) {
    res.status(500).json({ error: err.message || 'Failed' });
  }
});

router.get('/dashboard-state', requireAuth, (req, res) => {
  try {
    const state = socketService.buildDashboardState();
    res.json(state);
  } catch (err) {
    res.status(500).json({ error: err.message || 'Failed' });
  }
});

router.get('/settings', requireAuth, (req, res) => {
  try {
    const s = settingsService.get();
    res.json({
      defaultWebViewUrl: s.global_webview_url || '',
      pollingInterval: String(s.polling_interval_seconds ?? 25),
      judgeReleaseTimeoutSeconds: s.judge_release_timeout_seconds != null ? s.judge_release_timeout_seconds : 60,
      appTitle: s.app_title || 'Tablet Monitor',
      environmentLabel: s.environment_label || '',
      expectedWifiSsid: s.expected_wifi_ssid || '',
      kioskModeEnabled: !!(s.kiosk_mode_enabled_default != null ? s.kiosk_mode_enabled_default : 1),
    });
  } catch (err) {
    res.status(500).json({ error: err.message || 'Failed' });
  }
});

router.post('/settings', requireAuth, (req, res) => {
  try {
    const body = req.body || {};
    settingsService.update({
      global_webview_url: body.defaultWebViewUrl,
      polling_interval_seconds: body.pollingInterval,
      judge_release_timeout_seconds: body.judgeReleaseTimeoutSeconds,
      app_title: body.appTitle,
      environment_label: body.environmentLabel,
      expected_wifi_ssid: body.expectedWifiSsid,
      kiosk_mode_enabled_default: body.kioskModeEnabled ? 1 : 0,
    });
    res.json({ ok: true });
  } catch (err) {
    res.status(400).json({ error: err.message || 'Failed' });
  }
});

module.exports = router;
