const express = require('express');
const router = express.Router();
const { requireAuth } = require('../../middleware/auth');
const tabletService = require('../../services/tabletService');
const settingsService = require('../../services/settingsService');
const judgesService = require('../../services/judgesService');
const socketService = require('../../socket');
const { JUDGE_COLORS, getHex } = require('../../constants/judgeColors');
const { getStatusClass, getWifiSignalInfo } = require('../../utils/tabletStatus');

router.get('/dashboard', requireAuth, (req, res) => {
  const state = socketService.buildDashboardState();
  res.render('admin/dashboard', {
    title: 'Judge control',
    columns: state.columns,
    settings: state.settings,
    stats: state.stats,
    judgeColors: JUDGE_COLORS,
    getHex,
    username: req.session.adminUsername,
  });
});

router.get('/judges', requireAuth, (req, res) => {
  const initialState = (typeof socketService.buildJudgesState === 'function')
    ? socketService.buildJudgesState()
    : { judges: [] };
  const list = judgesService.listWithTabletStatus();
  const fallbackByLetter = {};
  list.forEach((j) => {
    const key = (j.judge_letter || '').toString().trim().toUpperCase();
    if (key) fallbackByLetter[key] = j;
  });
  const judges = (initialState.judges || []).map((j) => {
    const fallback = fallbackByLetter[(j.judge_letter || '').toString().trim().toUpperCase()] || {};
    const hasPassword = !!(fallback.password && String(fallback.password).trim());
    return {
      ...fallback,
      ...j,
      device_id: j.current_tablet_id || '',
      online: j.online === true,
      hasPassword,
    };
  });
  res.render('admin/judges', {
    title: 'Judges',
    judges,
    judgeColors: JUDGE_COLORS,
    getHex,
    username: req.session.adminUsername,
  });
});

router.get('/judges/edit/:id', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const judge = judgesService.getById(id);
  if (!judge) return res.redirect('/admin/judges');
  const judges = judgesService.list();
  res.render('admin/judge-edit', {
    title: 'Edit judge',
    judge,
    judges,
    judgeColors: JUDGE_COLORS,
    getHex,
    username: req.session.adminUsername,
  });
});

router.get('/judges/:id/password', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const judge = judgesService.getById(id);
  if (!judge) return res.status(404).json({ error: 'Not found' });
  res.json({ password: judge.password || '' });
});

router.post('/judges', requireAuth, (req, res) => {
  try {
    judgesService.create({
      judge_name: req.body.judge_name,
      judge_color: req.body.judge_color,
      judge_letter: req.body.judge_letter || '',
      username: req.body.username,
      password: req.body.password || '',
    });
    req.session.flash = { type: 'success', message: 'Judge added' };
    if (socketService.pushDashboardToAdmin) socketService.pushDashboardToAdmin('judge_changed');
  } catch (err) {
    req.session.flash = { type: 'error', message: err.message || 'Failed' };
  }
  res.redirect('/admin/judges');
});

router.post('/judges/:id/update', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  try {
    const payload = {
      judge_name: req.body.judge_name,
      judge_color: req.body.judge_color,
      judge_letter: req.body.judge_letter != null ? String(req.body.judge_letter).trim().toUpperCase() : undefined,
      username: req.body.username,
    };
    if (req.body.password !== undefined && String(req.body.password).trim() !== '') payload.password = req.body.password;
    judgesService.update(id, payload);
    req.session.flash = { type: 'success', message: 'Judge updated' };
    if (socketService.pushDashboardToAdmin) socketService.pushDashboardToAdmin('judge_changed');
  } catch (err) {
    req.session.flash = { type: 'error', message: err.message || 'Failed' };
  }
  res.redirect(req.body.redirect || '/admin/judges');
});

router.post('/judges/:id/delete', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  try {
    judgesService.remove(id);
    req.session.flash = { type: 'success', message: 'Judge deleted' };
    if (socketService.pushDashboardToAdmin) socketService.pushDashboardToAdmin('judge_changed');
  } catch (err) {
    req.session.flash = { type: 'error', message: err.message || 'Failed' };
  }
  res.redirect('/admin/judges');
});

router.get('/tablets', requireAuth, (req, res) => {
  const filters = {
    search: req.query.search || '',
    judgeLetter: req.query.judgeLetter || '',
    status: req.query.status || '',
    lowBattery: req.query.lowBattery === '1',
    wifiSsid: req.query.wifiSsid || '',
    wrongNetwork: req.query.wrongNetwork === '1',
  };
  const rawTablets = tabletService.list(filters);
  const listState = (typeof socketService.buildTabletsListState === 'function') ? socketService.buildTabletsListState() : { tablets: [] };
  const liveByDevice = {};
  (listState.tablets || []).forEach((row) => {
    if (row.device_id) liveByDevice[row.device_id] = { latency_ms: row.latency_ms, app_active: row.app_active };
  });
  const tablets = rawTablets.map((t) => {
    const tabletColorHex = getHex(t.tablet_color) || '#6b7280';
    const live = liveByDevice[t.device_id] || {};
    return {
      ...t,
      isLiveOnline: socketService.isTabletLiveOnline(t.device_id),
      tabletColorHex,
      latency_ms: live.latency_ms != null ? live.latency_ms : null,
      app_active: live.hasOwnProperty('app_active') ? live.app_active : null,
    };
  });
  const stats = {
    total: tablets.length,
    online: tablets.filter((t) => t.isLiveOnline).length,
    offline: tablets.filter((t) => !t.isLiveOnline).length,
    lowBattery: tablets.filter((t) => t.battery_level != null && t.battery_level < 20).length,
  };
  const settings = settingsService.get();
  res.render('admin/tablets-list', {
    title: 'Tablets',
    tablets,
    stats,
    settings,
    filters,
    getStatusClass,
    username: req.session.adminUsername,
  });
});

router.get('/tablets/:id', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const tablet = tabletService.findById(id);
  if (!tablet) return res.redirect('/admin/dashboard');
  const settings = settingsService.get();
  const targetUrl = (tablet.custom_webview_url && tablet.custom_webview_url.trim())
    ? tablet.custom_webview_url
    : settings.global_webview_url || '';
  const tabletColorHex = getHex(tablet.tablet_color) || '#6b7280';
  const liveData = (typeof socketService.getTabletLiveData === 'function') ? socketService.getTabletLiveData(tablet.device_id) : {};
  const tabletWithLive = {
    ...tablet,
    computedTargetUrl: targetUrl,
    isLiveOnline: socketService.isTabletLiveOnline(tablet.device_id),
    tabletColorHex,
    latency_ms: liveData.latency_ms != null ? liveData.latency_ms : tablet.latency_ms,
    app_active: liveData.hasOwnProperty('app_active') ? liveData.app_active : tablet.app_active,
  };
  res.render('admin/tablet-detail', {
    title: `Tablet: ${tablet.device_id}`,
    tablet: tabletWithLive,
    settings,
    getStatusClass,
    getWifiSignalInfo,
    username: req.session.adminUsername,
  });
});

router.post('/tablets/:id/update', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  try {
    tabletService.updateTablet(id, {
      judge_name: req.body.judge_name,
      judge_letter: req.body.judge_letter,
      judge_color: req.body.judge_color,
      tablet_label: req.body.tablet_label,
      custom_webview_url: req.body.custom_webview_url,
      note: req.body.note,
    });
    req.session.flash = { type: 'success', message: 'Tablet updated' };
    if (socketService.pushDashboardToAdmin) socketService.pushDashboardToAdmin('tablet_changed');
  } catch (err) {
    req.session.flash = { type: 'error', message: err.message || 'Update failed' };
  }
  res.redirect(`/admin/tablets/${id}`);
});

router.post('/tablets/:id/force-reload', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  try {
    tabletService.setForceReload(id);
    req.session.flash = { type: 'success', message: 'Force reload sent' };
    if (socketService.pushDashboardToAdmin) socketService.pushDashboardToAdmin('tablet_changed');
  } catch (err) {
    req.session.flash = { type: 'error', message: err.message || 'Failed' };
  }
  res.redirect(`/admin/tablets/${id}`);
});

router.post('/tablets/:id/delete', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  try {
    tabletService.deleteTablet(id);
    req.session.flash = { type: 'success', message: 'Tablet deleted' };
    if (socketService.pushDashboardToAdmin) socketService.pushDashboardToAdmin('tablet_changed');
  } catch (err) {
    req.session.flash = { type: 'error', message: err.message || 'Delete failed' };
  }
  res.redirect('/admin/tablets');
});

router.post('/tablets/:id/pending-action', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const action = (req.body.action || '').trim().toLowerCase();
  try {
    let payload = req.body.payload || null;
    if (action === 'force_judge_assignment') {
      const letter = (req.body.judge_letter || (payload && payload.judgeLetter) || '').toString().trim().toUpperCase();
      if (!letter) throw new Error('Judge letter required for Assign Judge');
      payload = tabletService.forceAssignJudge(id, letter);
      const tablet = tabletService.findById(id);
      if (tablet && tablet.device_id) {
        socketService.sendCommandToTablet(tablet.device_id, action, payload);
      }
      // Always push to admin — sendCommandToTablet only pushes when tablet is online.
      if (socketService.pushDashboardToAdmin) socketService.pushDashboardToAdmin('judge_assigned');
      req.session.flash = { type: 'success', message: `Judge ${payload.judgeLetter} assigned to tablet` };
      socketService.broadcastToAdmin('admin_notification', { title: 'A.S JUDGE', body: `Judge ${payload.judgeLetter} assigned to tablet` });
      return res.redirect(req.body.redirect || '/admin/dashboard');
    }
    tabletService.setPendingAction(id, action, payload);
    const tablet = tabletService.findById(id);
    if (tablet && tablet.device_id) {
      socketService.sendCommandToTablet(tablet.device_id, action, payload);
    }
    if (socketService.pushDashboardToAdmin) socketService.pushDashboardToAdmin('action_sent');
    const msg = action === 'login_webview' ? 'Login sent to tablet' : action === 'logout_webview' ? 'Logout sent to tablet' : action === 'clear_session' ? 'Clear session sent' : action === 'edit_judge_setup' ? 'Edit Judge Setup sent to tablet' : 'Reload sent';
    req.session.flash = { type: 'success', message: msg };
    socketService.broadcastToAdmin('admin_notification', { title: 'A.S JUDGE', body: msg });
  } catch (err) {
    req.session.flash = { type: 'error', message: err.message || 'Failed' };
  }
  res.redirect(req.body.redirect || '/admin/dashboard');
});

router.post('/tablets/:id/clear-webview-override', requireAuth, (req, res) => {
  const id = parseInt(req.params.id, 10);
  try {
    tabletService.clearWebviewOverride(id);
    req.session.flash = { type: 'success', message: 'Custom URL cleared; tablet will use global default' };
    if (socketService.pushDashboardToAdmin) socketService.pushDashboardToAdmin('tablet_changed');
  } catch (err) {
    req.session.flash = { type: 'error', message: err.message || 'Failed' };
  }
  res.redirect(`/admin/tablets/${id}`);
});

router.get('/settings', requireAuth, (req, res) => {
  const settings = settingsService.get();
  const flash = req.session.flash || null;
  delete req.session.flash;
  res.render('admin/settings', {
    title: 'Settings',
    settings,
    flash,
    username: req.session.adminUsername,
  });
});

router.post('/settings/update', requireAuth, (req, res) => {
  try {
    settingsService.update({
      global_webview_url: req.body.global_webview_url,
      polling_interval_seconds: req.body.polling_interval_seconds,
      judge_release_timeout_seconds: req.body.judge_release_timeout_seconds,
      app_title: req.body.app_title,
      environment_label: req.body.environment_label,
      expected_wifi_ssid: req.body.expected_wifi_ssid,
      kiosk_mode_enabled_default: req.body.kiosk_mode_enabled_default,
      admin_tablet_alerts_enabled: req.body.admin_tablet_alerts_enabled,
      telegram_bot_token: req.body.telegram_bot_token,
      telegram_chat_id: req.body.telegram_chat_id,
    });
    req.session.flash = { type: 'success', message: 'Settings updated' };
    if (socketService.pushDashboardToAdmin) socketService.pushDashboardToAdmin('settings_changed');
  } catch (err) {
    req.session.flash = { type: 'error', message: err.message || 'Update failed' };
  }
  res.redirect('/admin/settings');
});

router.get('/settings/telegram-updates', requireAuth, async (req, res) => {
  const settings = settingsService.get();
  const token = (settings.telegram_bot_token || '').trim();
  if (!token) return res.json({ ok: false, error: 'No bot token saved' });
  try {
    const result = await require('../../services/telegramService').getUpdates(token);
    res.json(result);
  } catch (err) {
    res.json({ ok: false, error: err.message });
  }
});

router.post('/settings/telegram-test', requireAuth, async (req, res) => {
  const settings = settingsService.get();
  const token = (settings.telegram_bot_token || '').trim();
  const chatId = (settings.telegram_chat_id || '').trim();
  if (!token || !chatId) {
    req.session.flash = { type: 'error', message: 'Save Bot Token and Chat ID first before testing.' };
    return res.redirect('/admin/settings');
  }
  try {
    const telegramService = require('../../services/telegramService');
    const result = await telegramService.sendMessage(token, chatId, 'AS Judge: test notification sent successfully.');
    if (result.ok) {
      req.session.flash = { type: 'success', message: 'Test message sent to Telegram!' };
    } else {
      req.session.flash = { type: 'error', message: `Telegram error: ${result.description || result.error || 'Unknown error'}` };
    }
  } catch (err) {
    req.session.flash = { type: 'error', message: `Failed: ${err.message}` };
  }
  res.redirect('/admin/settings');
});

module.exports = router;
