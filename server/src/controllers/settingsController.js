const Settings = require('../models/Settings');
const { isValidUrl } = require('../middleware/validate');

function settingsPage(req, res) {
  const settings = Settings.get();
  res.render('settings', {
    title: 'Settings',
    settings,
    error: req.flash('error'),
    success: req.flash('success'),
    admin: { username: req.session.adminUsername },
  });
}

function updateSettings(req, res) {
  try {
    const { global_webview_url, polling_interval_seconds, app_title, environment_label } = req.body;

    if (!global_webview_url || !isValidUrl(global_webview_url)) {
      req.flash('error', 'Invalid WebView URL');
      return res.redirect('/admin/settings');
    }

    const interval = parseInt(polling_interval_seconds, 10);
    if (isNaN(interval) || interval < 5 || interval > 300) {
      req.flash('error', 'Polling interval must be between 5-300 seconds');
      return res.redirect('/admin/settings');
    }

    Settings.update({
      globalWebviewUrl: global_webview_url.trim(),
      pollingIntervalSeconds: interval,
      appTitle: (app_title || 'Arabian Show Judge').trim(),
      environmentLabel: (environment_label || '').trim(),
    });

    req.flash('success', 'Settings updated successfully');
    return res.redirect('/admin/settings');
  } catch (err) {
    console.error('Settings update error:', err);
    req.flash('error', 'Failed to update settings');
    return res.redirect('/admin/settings');
  }
}

module.exports = { settingsPage, updateSettings };
